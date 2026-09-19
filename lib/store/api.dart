import 'dart:async';
import 'dart:math';

/// Stand-in backend. Each method has a switch that makes it misbehave the way
/// a real one does — an empty page, a duplicated row, a field that is null
/// once a session expires.
class StoreApi {
  StoreApi({required this.faults});

  final FaultSwitches faults;
  final _random = Random();

  Future<List<Product>> catalogue() async {
    await _latency();
    if (faults.emptyCatalogue) return const [];
    return const [
      Product('sku-1', 'Cotton T-Shirt', 149900),
      Product('sku-2', 'Denim Jacket', 799900),
      Product('sku-3', 'Canvas Sneakers', 429900),
      Product('sku-4', 'Wool Scarf', 219900),
    ];
  }

  Future<List<Order>> orders() async {
    await _latency();
    final orders = [
      const Order('ord-1001', 'Delivered', 149900),
      const Order('ord-1002', 'In transit', 799900),
    ];
    // A retried write upstream left two rows with the same id.
    if (faults.duplicateOrders) orders.add(orders.first);
    return orders;
  }

  /// `payment` is nullable in the contract: the server returns null once the
  /// checkout session has expired.
  Future<PaymentResponse> startPayment(int amountPaise) async {
    await _latency();
    if (faults.paymentApiDown) {
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

class FaultSwitches {
  bool emptyCatalogue = false;
  bool duplicateOrders = false;
  bool expiredSession = false;
  bool paymentApiDown = false;
}

class StoreApiException implements Exception {
  const StoreApiException(this.message);
  final String message;
  @override
  String toString() => 'StoreApiException: $message';
}

class Product {
  const Product(this.sku, this.name, this.paise);
  final String sku;
  final String name;
  final int paise;
}

class Order {
  const Order(this.id, this.status, this.paise);
  final String id;
  final String status;
  final int paise;
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

String rupees(int paise) => '₹${(paise / 100).toStringAsFixed(0)}';
