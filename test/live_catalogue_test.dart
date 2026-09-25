import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:rsod_demo/main.dart';
import 'package:rsod_demo/store/api.dart';
import 'package:rsod_demo/store/live_catalogue.dart';

/// One row in DummyJSON's shape, with the fields `select=` asks for and
/// nothing else. Copied from a real response so the mapping is tested
/// against what the API actually sends, not what it is assumed to send.
Map<String, dynamic> _row(String category) => {
      'id': 11,
      'sku': 'FUR-ANN-ANN-011',
      'title': 'Annibale Colombo Bed',
      'price': 1899.99,
      'category': category,
      'rating': 4.77,
      'stock': 88,
      'thumbnail':
          'https://cdn.dummyjson.com/product-images/furniture/annibale-colombo-bed/thumbnail.webp',
    };

http.Response _ok(Uri url) {
  final category = url.pathSegments.last;
  return http.Response(
    jsonEncode({
      'products': [_row(category)],
      'total': 1,
      'skip': 0,
      'limit': 5,
    }),
    200,
    headers: {'content-type': 'application/json'},
  );
}

void main() {
  late Directory cache;
  Future<Directory> cacheDir() async => cache;

  setUp(() {
    cache = Directory.systemTemp.createTempSync('catalogue-cache');
    addTearDown(() => cache.deleteSync(recursive: true));
  });

  test('the live catalogue is off unless a build asks for it', () {
    // The guarantee the four widget tests rest on: with no --dart-define,
    // nothing in the app can reach the network.
    expect(useLiveCatalogue, isFalse);
    expect(api.source, isA<MockCatalogue>());
    expect(api.source.isLive, isFalse);
  });

  test('maps a DummyJSON row onto the store model', () async {
    final product = productFromJson(_row('furniture'));

    expect(product.sku, 'FUR-ANN-ANN-011');
    expect(product.name, 'Annibale Colombo Bed');
    // The API's dollars, to the cent, not a converted price nobody can
    // check on stage.
    expect(product.paise, 189999);
    expect(product.price, '\$1,899.99');
    expect(product.category, 'furniture');
    expect(product.rating, 4.77);
    expect(product.inStock, 88);
    // The photo is the API's; the tile under it still follows the category.
    expect(product.photoUrl, endsWith('annibale-colombo-bed/thumbnail.webp'));
    expect(product.imageAsset, 'assets/products/furniture.png');
  });

  test('dollars group by thousands and keep the cents', () {
    expect(dollars(999), '\$9.99');
    expect(dollars(189999), '\$1,899.99');
    expect(dollars(1234567850), '\$12,345,678.50');
    // The bundled catalogue stays in rupees.
    expect(kCatalogue.first.price, startsWith('₹'));
  });

  test('an unlisted category still gets a bundled tile', () {
    expect(tileFor('smartphones'), 'store');
    expect(File('assets/products/store.png').existsSync(), isTrue);
  });

  test('every listed category has a tile on disk', () {
    for (final slug in kLiveCategories) {
      expect(File('assets/products/$slug.png').existsSync(), isTrue,
          reason: 'missing tile for $slug');
    }
  });

  test('fetches one page per category and asks only for the fields it uses',
      () async {
    final requested = <Uri>[];
    final catalogue = LiveCatalogue(
      client: MockClient((request) async {
        requested.add(request.url);
        return _ok(request.url);
      }),
      cacheDir: cacheDir,
      faults: FaultSwitches(),
    );

    final products = await catalogue.fetch();

    expect(products, hasLength(kLiveCategories.length));
    expect(
      requested.map((u) => u.pathSegments.last),
      containsAll(kLiveCategories),
    );
    for (final url in requested) {
      expect(url.host, 'dummyjson.com');
      expect(url.queryParameters['select'],
          'sku,title,price,category,rating,stock,thumbnail');
    }
  });

  test('products whose photo carries a logo never reach the shop', () async {
    final catalogue = LiveCatalogue(
      client: MockClient((request) async => http.Response(
            jsonEncode({
              'products': [
                {..._row('sports-accessories'), 'sku': 'SPO-BRD-BAS-140'},
                {..._row('womens-bags'), 'sku': 'WOM-PRA-PRA-174'},
                _row('furniture'),
              ],
            }),
            200,
          )),
      cacheDir: cacheDir,
      faults: FaultSwitches(),
    );

    final products = await catalogue.fetch();

    expect(products.map((p) => p.sku), everyElement('FUR-ANN-ANN-011'));
    expect(products.map((p) => p.sku),
        isNot(anyOf(contains('SPO-BRD-BAS-140'), contains('WOM-PRA-PRA-174'))));
  });

  test('a good response becomes the cache the next failure reads', () async {
    await LiveCatalogue(
      client: MockClient((request) async => _ok(request.url)),
      cacheDir: cacheDir,
      faults: FaultSwitches(),
    ).fetch();

    final offline = await LiveCatalogue(
      client: MockClient((_) async => throw const SocketException('offline')),
      cacheDir: cacheDir,
      faults: FaultSwitches(),
    ).fetch();

    expect(offline, hasLength(kLiveCategories.length));
    expect(offline.first.sku, 'FUR-ANN-ANN-011');
    // Round-tripping through the cache must not lose the price or photo.
    expect(offline.first.paise, 189999);
    expect(offline.first.photoUrl, endsWith('thumbnail.webp'));
  });

  test('a non-200 falls through to the cache as a failure does', () async {
    await LiveCatalogue(
      client: MockClient((request) async => _ok(request.url)),
      cacheDir: cacheDir,
      faults: FaultSwitches(),
    ).fetch();

    final degraded = await LiveCatalogue(
      client: MockClient((_) async => http.Response('gateway timeout', 503)),
      cacheDir: cacheDir,
      faults: FaultSwitches(),
    ).fetch();

    expect(degraded.first.sku, 'FUR-ANN-ANN-011');
  });

  test('one dead category costs that category, not the whole catalogue',
      () async {
    // dummyjson.com resets a connection now and then. Before this, a single
    // reset dropped all five categories to the cache; on stage that is a
    // stale shop for a fault nobody would otherwise have noticed.
    var refused = 0;
    final products = await LiveCatalogue(
      client: MockClient((request) async {
        if (request.url.pathSegments.last == kLiveCategories.first) {
          refused++;
          throw const SocketException('connection reset by peer');
        }
        return _ok(request.url);
      }),
      cacheDir: cacheDir,
      faults: FaultSwitches(),
    ).fetch();

    expect(refused, 1);
    expect(products, isNot(same(kCatalogue)));
    expect(products, hasLength(kLiveCategories.length - 1));
    expect(
      products.map((p) => p.category),
      isNot(contains(kLiveCategories.first)),
    );
  });

  test('every category failing still falls through to the cache', () async {
    await LiveCatalogue(
      client: MockClient((request) async => _ok(request.url)),
      cacheDir: cacheDir,
      faults: FaultSwitches(),
    ).fetch();

    final degraded = await LiveCatalogue(
      client: MockClient((_) async => throw const SocketException('offline')),
      cacheDir: cacheDir,
      faults: FaultSwitches(),
    ).fetch();

    expect(degraded.first.sku, 'FUR-ANN-ANN-011');
  });

  test(
      'every category failing reports the degrade once, and still serves '
      'the cache', () async {
    await LiveCatalogue(
      client: MockClient((request) async => _ok(request.url)),
      cacheDir: cacheDir,
      faults: FaultSwitches(),
    ).fetch();

    var reportCount = 0;
    final degraded = await LiveCatalogue(
      client: MockClient((_) async => throw const SocketException('offline')),
      cacheDir: cacheDir,
      faults: FaultSwitches(),
      reporter: (error, stack, context) {
        reportCount++;
        expect(error, isA<SocketException>());
        expect(context, contains('catalogue'));
      },
    ).fetch();

    expect(reportCount, 1);
    expect(degraded.first.sku, 'FUR-ANN-ANN-011');
  });

  test('one flaky category among successes does not report anything',
      () async {
    var reportCount = 0;
    final products = await LiveCatalogue(
      client: MockClient((request) async {
        if (request.url.pathSegments.last == kLiveCategories.first) {
          throw const SocketException('connection reset by peer');
        }
        return _ok(request.url);
      }),
      cacheDir: cacheDir,
      faults: FaultSwitches(),
      reporter: (error, stack, context) => reportCount++,
    ).fetch();

    expect(reportCount, 0);
    expect(products, hasLength(kLiveCategories.length - 1));
  });

  test('with no cache, a failure serves the bundled catalogue', () async {
    final products = await LiveCatalogue(
      client: MockClient((_) async => throw const SocketException('offline')),
      cacheDir: cacheDir,
      faults: FaultSwitches(),
    ).fetch();

    expect(products, same(kCatalogue));
  });

  test('an unreadable cache still degrades to the bundled catalogue',
      () async {
    File('${cache.path}/catalogue.json').writeAsStringSync('{not json');

    final products = await LiveCatalogue(
      client: MockClient((_) async => throw const SocketException('offline')),
      cacheDir: cacheDir,
      faults: FaultSwitches(),
    ).fetch();

    expect(products, same(kCatalogue));
  });

  test('the payment-API-down switch aims the request at a dead host',
      () async {
    final requested = <Uri>[];
    final catalogue = LiveCatalogue(
      client: MockClient((request) async {
        requested.add(request.url);
        throw const SocketException('Failed host lookup');
      }),
      cacheDir: cacheDir,
      faults: FaultSwitches()..paymentApiDown = true,
    );

    // The request is real and recorded; only its host is unreachable.
    expect(await catalogue.fetch(), same(kCatalogue));
    expect(requested, isNotEmpty);
    for (final url in requested) {
      expect(url.host, 'dummyjson.invalid');
    }
  });

  test('live mode leaves the fabricated 503 to mock mode', () async {
    final live = StoreApi(
      faults: FaultSwitches()..paymentApiDown = true,
      source: LiveCatalogue(
        client: MockClient((request) async => _ok(request.url)),
        cacheDir: cacheDir,
        faults: FaultSwitches(),
      ),
    );

    expect((await live.startPayment(1000)).payment?.id, 'pay-77');

    final mock = StoreApi(
      faults: FaultSwitches()..paymentApiDown = true,
      source: const MockCatalogue(),
    );

    expect(mock.startPayment(1000), throwsA(isA<StoreApiException>()));
  });
}
