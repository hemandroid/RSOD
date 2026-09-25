import 'package:flutter/material.dart';
import '../api.dart';
import '../../theme.dart';

class CartScreen extends StatefulWidget {
  const CartScreen({super.key});
  @override
  State<CartScreen> createState() => _CartScreenState();
}

class _CartScreenState extends State<CartScreen> {
  // Cosmetic only: nothing else in the app tracks a real cart, so this never
  // reflects what was actually "added" from the catalogue. Looked up from
  // the same catalogue feed the store screen uses (by sku, not position) so
  // the name, image and price can't drift from what the shop actually lists.
  int _qty = 1;
  // From the const list, not `api.catalogue()`: the API honours the
  // empty-catalogue fault, and the cart is not meant to break when that
  // fault is armed.
  final Product _item = kCatalogue.firstWhere((p) => p.sku == 'sku-2');

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Cart')),
      body: Builder(
        builder: (context) {
          final item = _item;
          final subtotal = item.paise * _qty;
          return ListView(
            padding: const EdgeInsets.all(20),
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          ClipRRect(
                            borderRadius:
                                BorderRadius.circular(NimbusTokens.radius),
                            child: Image.asset(
                              item.imageAsset,
                              width: 72,
                              height: 72,
                              fit: BoxFit.cover,
                            ),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  item.name,
                                  style: textTheme.titleMedium,
                                  overflow: TextOverflow.ellipsis,
                                  maxLines: 2,
                                ),
                                const SizedBox(height: 4),
                                Text(rupees(item.paise),
                                    style: textTheme.headlineSmall),
                              ],
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.delete_outline),
                            tooltip: 'Remove item',
                            color: colorScheme.secondary,
                            onPressed: () {},
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          _QuantityStepper(
                            qty: _qty,
                            onChanged: (next) => setState(() => _qty = next),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text('Price Summary', style: textTheme.titleMedium),
                      const SizedBox(height: 8),
                      _PriceRow(
                        label: 'Subtotal ($_qty item${_qty == 1 ? '' : 's'})',
                        value: rupees(subtotal),
                      ),
                      const _PriceRow(
                          label: 'Delivery charges', value: 'FREE'),
                      const Divider(height: 24),
                      _PriceRow(
                        label: 'Total',
                        value: rupees(subtotal),
                        emphasize: true,
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 24),
              FilledButton(
                onPressed: () => Navigator.pushNamed(context, '/checkout'),
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 22),
                ),
                child: const Text('Checkout'),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _QuantityStepper extends StatelessWidget {
  const _QuantityStepper({required this.qty, required this.onChanged});
  final int qty;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: NimbusTokens.surfaceContainer,
        borderRadius: BorderRadius.circular(NimbusTokens.radius),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: const Icon(Icons.remove),
            onPressed: qty > 1 ? () => onChanged(qty - 1) : null,
          ),
          SizedBox(
            width: 32,
            child: Text('$qty',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleMedium),
          ),
          IconButton(
            icon: const Icon(Icons.add),
            onPressed: qty < 9 ? () => onChanged(qty + 1) : null,
          ),
        ],
      ),
    );
  }
}

class _PriceRow extends StatelessWidget {
  const _PriceRow({
    required this.label,
    required this.value,
    this.emphasize = false,
  });
  final String label;
  final String value;
  final bool emphasize;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final style = emphasize ? textTheme.headlineSmall : textTheme.bodyLarge;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      // Expanded on the label: at 411dp with the 1.35x text scale a long
      // label plus an amount does not fit on one line.
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(
            child: Text(label, style: style, overflow: TextOverflow.ellipsis),
          ),
          const SizedBox(width: 12),
          Text(value, style: style),
        ],
      ),
    );
  }
}
