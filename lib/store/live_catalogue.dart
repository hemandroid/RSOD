import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:incident_sdk/incident_sdk.dart';

import 'api.dart';

/// The only categories this app will ask for. Every other DummyJSON
/// category is full of Apple, Nike and Nescafé products, whose names and
/// photos do not belong on a recorded stage.
const kLiveCategories = [
  'furniture',
  'kitchen-accessories',
  'home-decoration',
  'womens-bags',
  'sports-accessories',
];

/// Kept short so the whole catalogue still reads as one screen of product
/// rather than a scroll test.
const _kPerCategory = 5;

/// Products whose DummyJSON photo carries a visible logo, dropped from the
/// catalogue outright. Every thumbnail in [kLiveCategories] was checked by
/// eye on 25 Sep 2026: the basketball is printed with the Wilson wordmark
/// and the NBA logo, the Prada bag with its triangle badge. A logo in the
/// Jira screenshot is a legal problem rather than a demo.
const kBrandedSkus = {'SPO-BRD-BAS-140', 'WOM-PRA-PRA-174'};

/// Bundled tile for [category], shown under a live product's photo until it
/// loads and whenever it fails. Keyed by category, not by product, so a tile
/// exists for whatever the API returns.
String tileFor(String category) =>
    kLiveCategories.contains(category) ? category : 'store';

/// One DummyJSON product row as the store's own model.
///
/// `price` stays in US dollars, the API's own currency, rather than being
/// converted: inventing an exchange rate would put a made-up price on
/// screen. DummyJSON's `reviews` is three fabricated review
/// objects, never a count, so nothing here maps to a review total.
Product productFromJson(Map<String, dynamic> json) {
  final category = json['category'] as String;
  return Product(
    json['sku'] as String,
    json['title'] as String,
    ((json['price'] as num) * 100).round(),
    image: tileFor(category),
    category: category,
    rating: (json['rating'] as num).toDouble(),
    inStock: (json['stock'] as num).toInt(),
    photoUrl: json['thumbnail'] as String?,
    inDollars: true,
  );
}

/// The catalogue over real HTTP, with two fallback levels beneath it: the
/// last good response on disk, then the bundled [kCatalogue]. A failed
/// fetch must degrade the data, never leave an empty screen.
class LiveCatalogue implements Catalogue {
  LiveCatalogue({
    required this.client,
    required this.cacheDir,
    required this.faults,
    void Function(Object error, StackTrace stack, String context)? reporter,
  }) : reporter = reporter ??
            ((error, stack, context) =>
                IncidentSDK.report(error, stack, context: context));

  /// Expected to be the SDK's `IncidentHttpClient`, which is most of the
  /// point of fetching over HTTP at all: the incident then carries the real
  /// request that failed rather than a description of one.
  final http.Client client;

  /// A callback, not a `Directory`: `path_provider` answers asynchronously
  /// and only on a real device, so tests hand over a temp directory instead.
  final Future<Directory> Function() cacheDir;

  final FaultSwitches faults;

  /// Defaults to `IncidentSDK.report`, the same handled-report call
  /// `catalogue.dart` uses for the empty catalogue. Overridable so a test can
  /// see whether a degraded fetch reported itself without a live SDK.
  final void Function(Object error, StackTrace stack, String context)
      reporter;

  static const _origin = 'https://dummyjson.com';

  /// `.invalid` is reserved by RFC 6761 and resolves nowhere, so the chaos
  /// switch produces a genuine SocketException against a URL the network
  /// collector really recorded.
  static const _deadOrigin = 'https://dummyjson.invalid';

  @override
  bool get isLive => true;

  @override
  Future<List<Product>> fetch() async {
    final origin = faults.paymentApiDown ? _deadOrigin : _origin;
    // Set whenever a category (or the fetch itself) fails, so a total outage
    // can be reported once below with a real error and stack rather than
    // just the warning log every individual failure already gets.
    Object? lastError;
    StackTrace? lastStack;
    try {
      // One request per category, all in flight together: a sequential loop
      // would make the first paint wait on five round trips.
      //
      // Each category absorbs its own failure rather than the batch failing
      // whole. dummyjson.com resets a connection occasionally — one transient
      // reset was observed while building this — and losing one category of
      // five is invisible on stage, whereas losing all five drops the screen
      // to stale cache in front of an audience.
      final pages = await Future.wait([
        for (final slug in kLiveCategories)
          _category(origin, slug).catchError((Object error, StackTrace stack) {
            lastError = error;
            lastStack = stack;
            IncidentSDK.log(
              'catalogue: category $slug failed ($error)',
              level: LogLevel.warning,
            );
            return <Product>[];
          }),
      ]);
      final products = [for (final page in pages) ...page];
      // Every category failing is a real outage, not a flake: fall through to
      // the cache rather than painting an empty shop.
      if (products.isNotEmpty) {
        await _writeCache(products);
        return products;
      }
    } catch (error, stack) {
      lastError = error;
      lastStack = stack;
      IncidentSDK.log(
        'catalogue: live fetch failed, downgrading ($error)',
        level: LogLevel.warning,
      );
    }

    // Every category failed (a partial failure already returned above), so
    // this is the real outage the warning logs above cannot file a ticket
    // for on their own. One report per degraded fetch, not per category: the
    // failed requests themselves are already on the network collector's
    // trail, this just ties them to an incident.
    if (lastError != null) {
      reporter(lastError!, lastStack!, 'catalogue: live fetch degraded');
    }

    final cached = await _readCache();
    if (cached != null) {
      IncidentSDK.log(
        'catalogue: serving ${cached.length} products from the disk cache',
        level: LogLevel.warning,
      );
      return cached;
    }

    IncidentSDK.log(
      'catalogue: no usable cache, serving the bundled catalogue',
      level: LogLevel.warning,
    );
    return kCatalogue;
  }

  Future<List<Product>> _category(String origin, String slug) async {
    // `select` rather than the whole row: the fields left out are the
    // gallery `images` and the fake reviews, neither of which this app
    // renders.
    final url = Uri.parse(
      '$origin/products/category/$slug'
      '?select=sku,title,price,category,rating,stock,thumbnail'
      '&limit=$_kPerCategory',
    );
    final response = await client.get(url);
    if (response.statusCode != 200) {
      throw StoreApiException('GET $url failed: ${response.statusCode}');
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return [
      for (final row in (body['products'] as List).cast<Map<String, dynamic>>())
        if (!kBrandedSkus.contains(row['sku'])) productFromJson(row),
    ];
  }

  Future<File> _cacheFile() async =>
      File('${(await cacheDir()).path}/catalogue.json');

  /// Written in the API's own field names so [productFromJson] reads both
  /// the live response and the cache — one mapper, one thing to get wrong.
  Future<void> _writeCache(List<Product> products) async {
    try {
      await (await _cacheFile()).writeAsString(jsonEncode([
        for (final p in products)
          {
            'sku': p.sku,
            'title': p.name,
            'price': p.paise / 100,
            'category': p.category,
            'rating': p.rating,
            'stock': p.inStock,
            'thumbnail': p.photoUrl,
          },
      ]));
    } catch (error) {
      // A cache that cannot be written costs a fallback level; it is not a
      // reason to fail a fetch that already succeeded.
      IncidentSDK.log(
        'catalogue: cache write failed ($error)',
        level: LogLevel.warning,
      );
    }
  }

  /// Null for every unusable cache — missing, corrupt, or empty — so the
  /// caller has one case to handle instead of four.
  Future<List<Product>?> _readCache() async {
    try {
      final file = await _cacheFile();
      if (!file.existsSync()) return null;
      final rows = jsonDecode(await file.readAsString()) as List;
      if (rows.isEmpty) return null;
      return [
        for (final row in rows) productFromJson(row as Map<String, dynamic>),
      ];
    } catch (error) {
      IncidentSDK.log(
        'catalogue: cache unreadable ($error)',
        level: LogLevel.warning,
      );
      return null;
    }
  }
}
