import 'dart:async';
import 'dart:math';

/// Stand-in backend. Each method has a switch that makes it misbehave the way
/// a real one does — an empty page, a duplicated row, a field that is null
/// once a session expires.
class StoreApi {
  StoreApi({required this.faults, required this.source});

  final FaultSwitches faults;

  /// Where `catalogue()` reads from. Swapped, not branched on: the live
  /// source has its own fallbacks and the mock one must stay reachable on
  /// any machine with no network.
  final Catalogue source;

  final _random = Random();

  Future<List<Product>> catalogue() async {
    // Live mode already waits on a real round trip; adding the fake one on
    // top would only make the API look slower than it is.
    if (!source.isLive) await _latency();
    if (faults.emptyCatalogue) return const [];
    return source.fetch();
  }

  /// Server-driven UI flags, shaped the way a remote-config service hands
  /// them over: a plain map in which a key the server never sent is absent,
  /// not false. The fault drops the one key the store reads.
  Map<String, Object?> get storeFlags =>
      faults.missingRemoteFlag ? const {} : const {'showItemCount': true};

  Future<List<Order>> orders() async {
    await _latency();
    final orders = [
      const Order('ord-1001', 'Delivered', 149900,
          placedOn: '18 Sep 2026',
          summary: 'Cotton Crew T-Shirt',
          image: 'tshirt',
          courier: 'BlueDart · AWB 4417820'),
      const Order('ord-1002', 'In transit', 799900,
          placedOn: '19 Sep 2026',
          summary: 'Denim Trucker Jacket',
          image: 'jacket',
          courier: 'Delhivery · AWB 9920114'),
      const Order('ord-1003', 'Out for delivery', 349900,
          placedOn: '20 Sep 2026',
          summary: 'Bluetooth ANC Earbuds',
          image: 'earbuds',
          courier: 'Ekart · AWB 3381907'),
      const Order('ord-1004', 'Processing', 89900,
          placedOn: '21 Sep 2026',
          summary: 'Insulated Steel Bottle',
          image: 'bottle',
          courier: 'Awaiting pickup'),
      const Order('ord-1005', 'Cancelled', 219900,
          placedOn: '12 Sep 2026',
          summary: 'Merino Wool Scarf',
          image: 'scarf',
          courier: 'Refund issued'),
    ];
    // A retried write upstream left two rows with the same id. Inserted next
    // to the original so both are on screen together — the duplicate is the
    // point, and it is invisible if it lands five rows further down.
    if (faults.duplicateOrders) orders.insert(1, orders.first);
    return orders;
  }

  /// `payment` is nullable in the contract: the server returns null once the
  /// checkout session has expired.
  Future<PaymentResponse> startPayment(int amountPaise) async {
    await _latency();
    // Only when there is no real network call to break. In live mode the
    // same switch aims the catalogue fetch at a dead host, and a fabricated
    // 503 next to that genuine SocketException is the weaker demo.
    if (faults.paymentApiDown && !source.isLive) {
      throw const StoreApiException('POST /payment failed: 503');
    }
    if (faults.expiredSession) {
      return const PaymentResponse(sessionId: 'sess-expired', payment: null);
    }
    return PaymentResponse(
      sessionId: 'sess-${_random.nextInt(9999)}',
      payment: const Payment('pay-77', 'authorised'),
    );
  }

  Future<void> _latency() =>
      Future<void>.delayed(Duration(milliseconds: 120 + _random.nextInt(180)));
}

/// Where the catalogue comes from. Two implementations because the demo
/// runs in two modes: off the bundled fixtures on any machine, and off a
/// real HTTP API when the cloud build is on stage.
abstract interface class Catalogue {
  Future<List<Product>> fetch();

  /// Whether a fault switch has a real request to break. A mock source has
  /// none, so its faults still have to be simulated in-process.
  bool get isLive;
}

/// The bundled fixtures, unchanged. Also the last fallback level of
/// `LiveCatalogue`, so this stays the shape everything else degrades to.
class MockCatalogue implements Catalogue {
  const MockCatalogue();

  @override
  bool get isLive => false;

  @override
  Future<List<Product>> fetch() async => kCatalogue;
}

/// The catalogue as data, separate from the method that serves it. The
/// cart reads this directly: routing a hardcoded demo cart through
/// `catalogue()` would make the 'catalogue returns nothing' fault break
/// the cart too, which is not a failure this demo is supposed to have.
const List<Product> kCatalogue = [
      Product('sku-1', 'Cotton Crew T-Shirt', 149900,
          image: 'tshirt',
          category: 'Apparel',
          rating: 4.3,
          inStock: 12),
      Product('sku-2', 'Denim Trucker Jacket', 799900,
          image: 'jacket',
          category: 'Apparel',
          rating: 4.7,
          inStock: 4),
      Product('sku-3', 'Canvas Court Sneakers', 429900,
          image: 'sneakers',
          category: 'Footwear',
          rating: 4.1,
          inStock: 23),
      Product('sku-4', 'Merino Wool Scarf', 219900,
          image: 'scarf',
          category: 'Accessories',
          rating: 4.5,
          inStock: 7),
      Product('sku-5', 'Full-Grain Leather Wallet', 189900,
          image: 'wallet',
          category: 'Accessories',
          rating: 4.6,
          inStock: 31),
      Product('sku-6', 'Bluetooth ANC Earbuds', 349900,
          image: 'earbuds',
          category: 'Electronics',
          rating: 4.2,
          inStock: 2),
      Product('sku-7', 'Insulated Steel Bottle', 89900,
          image: 'bottle',
          category: 'Lifestyle',
          rating: 4.4,
          inStock: 48),
      Product('sku-8', 'Cork Yoga Mat 6mm', 129900,
          image: 'yogamat',
          category: 'Lifestyle',
          rating: 4.0,
          inStock: 15),
];

class FaultSwitches {
  bool emptyCatalogue = false;
  bool duplicateOrders = false;
  bool expiredSession = false;
  bool paymentApiDown = false;
  bool missingRemoteFlag = false;
}

class StoreApiException implements Exception {
  const StoreApiException(this.message);
  final String message;
  @override
  String toString() => 'StoreApiException: $message';
}

class Product {
  const Product(
    this.sku,
    this.name,
    this.paise, {
    required this.image,
    required this.category,
    required this.rating,
    required this.inStock,
    this.photoUrl,
    this.inDollars = false,
  });

  final String sku;
  final String name;
  final int paise;

  /// Basename under `assets/products/`. Always bundled, even for a live
  /// product that also has a [photoUrl]: a network image on conference wifi
  /// is a spinner in front of an audience and a broken tile inside the Jira
  /// screenshot, so this tile is what shows until the photo lands and
  /// whenever it cannot.
  final String image;

  /// The API's own product photo, null for the bundled catalogue. Drawn by
  /// `ProductImage` over [image], never instead of it.
  final String? photoUrl;

  /// True for DummyJSON products, whose prices are US dollars. [paise] then
  /// holds cents: the amount is shown in the API's own currency rather than
  /// converted at an exchange rate nobody on stage could check.
  final bool inDollars;

  String get price => inDollars ? dollars(paise) : rupees(paise);

  final String category;
  final double rating;
  final int inStock;

  String get imageAsset => 'assets/products/$image.png';
}

class Order {
  const Order(
    this.id,
    this.status,
    this.paise, {
    required this.placedOn,
    required this.summary,
    required this.image,
    required this.courier,
  });

  final String id;
  final String status;
  final int paise;

  /// Display only — never parsed, so no format to keep in sync.
  final String placedOn;

  final String summary;
  final String image;
  final String courier;

  String get imageAsset => 'assets/products/$image.png';
}

class Payment {
  const Payment(this.id, this.status);
  final String id;
  final String status;
}

class PaymentResponse {
  const PaymentResponse({required this.sessionId, required this.payment});
  final String sessionId;
  final Payment? payment;
}

/// Grouped to Indian convention (₹7,999 and ₹1,24,500) rather than plain
/// digits: the app is priced in rupees, and an ungrouped six-figure number is
/// hard to read at a glance on a projector.
/// Western grouping and cents shown ($1,899.99): the API's prices are exact
/// to the cent, and rounding them would be a second, silent conversion.
String dollars(int cents) {
  final whole = (cents ~/ 100).toString();
  final grouped = StringBuffer();
  for (var i = 0; i < whole.length; i++) {
    if (i > 0 && (whole.length - i) % 3 == 0) grouped.write(',');
    grouped.write(whole[i]);
  }
  return '\$$grouped.${(cents % 100).toString().padLeft(2, '0')}';
}

String rupees(int paise) {
  final whole = (paise / 100).round().toString();
  if (whole.length <= 3) return '₹$whole';
  final head = whole.substring(0, whole.length - 3);
  final tail = whole.substring(whole.length - 3);
  final grouped = StringBuffer();
  for (var i = 0; i < head.length; i++) {
    if (i > 0 && (head.length - i) % 2 == 0) grouped.write(',');
    grouped.write(head[i]);
  }
  return '₹$grouped,$tail';
}
