import 'dart:async';

import 'package:flutter/material.dart';
import 'package:incident_sdk/incident_sdk.dart';

import '../main.dart';
import 'api.dart';

class CatalogueScreen extends StatefulWidget {
  const CatalogueScreen({super.key});
  @override
  State<CatalogueScreen> createState() => _CatalogueScreenState();
}

class _CatalogueScreenState extends State<CatalogueScreen> {
  late Future<List<Product>> _products = api.catalogue();

  Future<void> _reload() async {
    IncidentSDK.log('catalogue: reload requested');
    setState(() => _products = api.catalogue());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Nimbus Store'),
        actions: [
          IconButton(
            icon: const Icon(Icons.receipt_long, size: 28),
            onPressed: () => Navigator.pushNamed(context, '/orders'),
          ),
          IconButton(
            icon: const Icon(Icons.settings, size: 28),
            onPressed: () => Navigator.pushNamed(context, '/settings'),
          ),
        ],
      ),
      body: FutureBuilder<List<Product>>(
        future: _products,
        builder: (context, snap) {
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final products = snap.data!;
          return ListView(
            padding: const EdgeInsets.all(20),
            children: [
              // The banner assumes the catalogue is never empty. When the API
              // returns [] this throws, and the SDK reports it as a handled
              // failure rather than a crash.
              _FeaturedBanner(products: products),
              const SizedBox(height: 20),
              for (final p in products)
                Card(
                  child: ListTile(
                    contentPadding: const EdgeInsets.all(16),
                    title: Text(p.name),
                    subtitle: Text(rupees(p.paise)),
                    trailing: FilledButton(
                      onPressed: () => Navigator.pushNamed(context, '/cart'),
                      child: const Text('Add'),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _reload,
        icon: const Icon(Icons.refresh),
        label: const Text('Reload'),
      ),
    );
  }
}

class _FeaturedBanner extends StatelessWidget {
  const _FeaturedBanner({required this.products});
  final List<Product> products;

  @override
  Widget build(BuildContext context) {
    late final Product featured;
    try {
      featured = products.first;
    } catch (error, stack) {
      IncidentSDK.report(error, stack, context: 'catalogue: empty page');
      return const Card(
        child: ListTile(title: Text('Nothing featured today')),
      );
    }
    return Card(
      color: Theme.of(context).colorScheme.primaryContainer,
      child: ListTile(
        contentPadding: const EdgeInsets.all(20),
        title: Text('Featured: ${featured.name}'),
        subtitle: Text(rupees(featured.paise)),
      ),
    );
  }
}

class CartScreen extends StatelessWidget {
  const CartScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Cart')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Card(
              child: ListTile(
                contentPadding: EdgeInsets.all(20),
                title: Text('Denim Jacket'),
                subtitle: Text('₹7,999'),
              ),
            ),
            const Spacer(),
            FilledButton(
              onPressed: () => Navigator.pushNamed(context, '/checkout'),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 22),
              ),
              child: const Text('Checkout'),
            ),
          ],
        ),
      ),
    );
  }
}

class CheckoutScreen extends StatefulWidget {
  const CheckoutScreen({super.key});
  @override
  State<CheckoutScreen> createState() => _CheckoutScreenState();
}

class _CheckoutScreenState extends State<CheckoutScreen> {
  bool _busy = false;

  Future<void> _pay() async {
    setState(() => _busy = true);
    IncidentSDK.log('checkout: starting payment for 799900 paise');
    final response = await api.startPayment(799900);
    if (!mounted) return;

    // `payment` is nullable in the API contract — the server returns null once
    // the session has expired — but this path assumes it is always present.
    final payment = response.payment!;

    setState(() => _busy = false);
    Navigator.pushNamed(context, '/confirmation', arguments: payment.id);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Checkout')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Total ${rupees(799900)}',
                style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 24),
            // Card and address are real user data, so they never reach a
            // screenshot.
            IncidentMask(
              child: Column(
                children: const [
                  TextField(decoration: InputDecoration(labelText: 'Card number')),
                  SizedBox(height: 16),
                  TextField(decoration: InputDecoration(labelText: 'Address')),
                ],
              ),
            ),
            const Spacer(),
            FilledButton(
              onPressed: _busy ? null : _pay,
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 22),
              ),
              child: Text(_busy ? 'Contacting bank…' : 'Pay now'),
            ),
          ],
        ),
      ),
    );
  }
}

class OrdersScreen extends StatefulWidget {
  const OrdersScreen({super.key});
  @override
  State<OrdersScreen> createState() => _OrdersScreenState();
}

class _OrdersScreenState extends State<OrdersScreen> {
  late final Future<List<Order>> _orders = api.orders();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Your orders')),
      body: FutureBuilder<List<Order>>(
        future: _orders,
        builder: (context, snap) {
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final orders = snap.data!;
          return ListView(
            padding: const EdgeInsets.all(20),
            children: [
              for (final order in orders)
                Card(
                  child: ListTile(
                    contentPadding: const EdgeInsets.all(16),
                    title: Text(order.id),
                    subtitle: Text(order.status),
                    trailing: Text(rupees(order.paise)),
                    // Looking the order back up by id: `singleWhere` throws
                    // when a retried write has left two rows with the same id.
                    onTap: () {
                      final found =
                          orders.singleWhere((o) => o.id == order.id);
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Order ${found.id}')),
                      );
                    },
                    leading: IconButton(
                      icon: const Icon(Icons.local_shipping_outlined, size: 28),
                      tooltip: 'Track shipment',
                      // The tracking screen was removed in a refactor; this
                      // push still references it.
                      onPressed: () =>
                          Navigator.pushNamed(context, '/tracking'),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  /// Rebuilding the local index on the main thread. Fine for a few hundred
  /// orders in testing, not for a year of them.
  void _rebuildIndex() {
    IncidentSDK.log('settings: rebuilding local index');
    final sink = StringBuffer();
    final until = DateTime.now().add(const Duration(seconds: 7));
    while (DateTime.now().isBefore(until)) {
      sink.write(DateTime.now().microsecondsSinceEpoch.toString());
      if (sink.length > 2000000) sink.clear();
    }
  }

  void _syncInBackground() {
    IncidentSDK.log('settings: background sync started');
    unawaited(Future<void>(() async {
      await Future<void>.delayed(const Duration(milliseconds: 150));
      throw const StoreApiException('background sync: token refresh failed');
    }));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          SwitchListTile(
            title: const Text('Catalogue returns nothing'),
            value: faults.emptyCatalogue,
            onChanged: (v) => setState(() => faults.emptyCatalogue = v),
          ),
          SwitchListTile(
            title: const Text('Order history has duplicates'),
            value: faults.duplicateOrders,
            onChanged: (v) => setState(() => faults.duplicateOrders = v),
          ),
          SwitchListTile(
            title: const Text('Checkout session expired'),
            value: faults.expiredSession,
            onChanged: (v) => setState(() => faults.expiredSession = v),
          ),
          SwitchListTile(
            title: const Text('Payment API down'),
            value: faults.paymentApiDown,
            onChanged: (v) => setState(() => faults.paymentApiDown = v),
          ),
          const Divider(height: 40),
          ListTile(
            title: const Text('Rebuild local index'),
            subtitle: const Text('Blocks the UI thread'),
            trailing: const Icon(Icons.warning_amber, size: 28),
            onTap: _rebuildIndex,
          ),
          ListTile(
            title: const Text('Sync in background'),
            subtitle: const Text('Throws off the main isolate'),
            trailing: const Icon(Icons.sync_problem, size: 28),
            onTap: _syncInBackground,
          ),
        ],
      ),
    );
  }
}

class ConfirmationScreen extends StatelessWidget {
  const ConfirmationScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final paymentId = ModalRoute.of(context)?.settings.arguments as String?;
    return Scaffold(
      appBar: AppBar(title: const Text('Order confirmed')),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.check_circle, size: 96, color: Colors.green),
            const SizedBox(height: 24),
            Text('Payment ${paymentId ?? "unknown"}',
                style: Theme.of(context).textTheme.headlineSmall),
          ],
        ),
      ),
    );
  }
}
