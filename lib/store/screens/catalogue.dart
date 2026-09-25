import 'dart:async';
import 'package:flutter/material.dart';
import 'package:incident_sdk/incident_sdk.dart';
import '../../main.dart';
import '../api.dart';
import '../../theme.dart';
import 'product_image.dart';

class CatalogueScreen extends StatefulWidget {
  const CatalogueScreen({super.key});
  @override
  State<CatalogueScreen> createState() => _CatalogueScreenState();
}

class _CatalogueScreenState extends State<CatalogueScreen> {
  late Future<List<Product>> _products = api.catalogue();

  Future<void> _reload() async {
    IncidentSDK.log('catalogue: reload requested');
    // Block body, not `=>`: an arrow would return the assigned Future and
    // setState rejects a callback that returns one.
    setState(() {
      _products = api.catalogue();
    });
  }

  // The shell keeps every tab mounted in an IndexedStack, so "adding to cart"
  // is a tab switch, not a route push.
  void _goToCart() => shellTab.value = 1;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Nimbus Store'),
        actions: [
          IconButton(
            icon: const Icon(Icons.receipt_long, size: 28),
            tooltip: 'Orders',
            // Orders is a shell tab now, not a route; pushing '/orders' would be
            // a second broken navigation on top of the deliberate one.
            onPressed: () => shellTab.value = 2,
          ),
          IconButton(
            icon: const Icon(Icons.settings, size: 28),
            tooltip: 'Settings',
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
          // `as bool` trusts the server to always send the flag. When the key
          // is missing the cast throws while this list is being built, and
          // Flutter replaces the whole list with its error box: the red screen.
          final showItemCount = api.storeFlags['showItemCount'] as bool;
          return ListView(
            // Extra bottom padding: the Reload FAB floats over the last card
            // and was covering its Add button.
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 104),
            children: [
              // The banner assumes the catalogue is never empty. When the API
              // returns [] this throws, and the SDK reports it as a handled
              // failure rather than a crash.
              _FeaturedBanner(products: products, onAddToCart: _goToCart),
              const SizedBox(height: 20),
              // Both sides flex: the design was drawn 780px wide, the device is
              // ~411dp, and every label is multiplied by the 1.35x projector
              // text scale. Fixed-width children overflow at that combination.
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.grid_view,
                            color: Theme.of(context).colorScheme.primary),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            'Trending Products',
                            style: Theme.of(context).textTheme.titleLarge,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  if (showItemCount)
                    Text('${products.length} items',
                        style: Theme.of(context).textTheme.bodyMedium),
                ],
              ),
              const SizedBox(height: 12),
              if (products.isEmpty)
                _EmptyProductList(onReload: _reload)
              else
                for (final p in products)
                  _ProductRow(product: p, onAdd: _goToCart),
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
  const _FeaturedBanner({required this.products, required this.onAddToCart});
  final List<Product> products;
  final VoidCallback onAddToCart;

  @override
  Widget build(BuildContext context) {
    late final Product featured;
    try {
      featured = products.first;
    } catch (error, stack) {
      IncidentSDK.report(error, stack, context: 'catalogue: empty page');
      return Card(
        color: NimbusTokens.surfaceContainer,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.campaign_outlined,
                  size: 40, color: Theme.of(context).colorScheme.secondary),
              const SizedBox(width: 16),
              const Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Nothing featured today'),
                    SizedBox(height: 4),
                    Text('Check back soon for limited-time offers'),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    }

    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Align, not just the Container's own sizing: the parent Column
            // is stretch-aligned (so the image and button below go full
            // width), and without this the pill would stretch too.
            Align(
              alignment: Alignment.centerLeft,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: colorScheme.primaryContainer.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(NimbusTokens.radius * 2),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.local_fire_department,
                        size: 16, color: colorScheme.primary),
                    const SizedBox(width: 4),
                    Text('Featured Deal',
                        style: textTheme.bodyMedium
                            ?.copyWith(color: colorScheme.primary)),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(NimbusTokens.radius),
              child: ProductImage(
                featured,
                height: 140,
                width: double.infinity,
              ),
            ),
            const SizedBox(height: 16),
            Text('Featured: ${featured.name}', style: textTheme.titleLarge),
            const SizedBox(height: 4),
            Text(featured.price, style: textTheme.headlineSmall),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: onAddToCart,
              child: const Text('Add to cart'),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyProductList extends StatelessWidget {
  const _EmptyProductList({required this.onReload});
  final VoidCallback onReload;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.inventory_2_outlined,
                size: 56, color: Theme.of(context).colorScheme.primary),
            const SizedBox(height: 16),
            Text('No products available',
                textAlign: TextAlign.center, style: textTheme.headlineSmall),
            const SizedBox(height: 8),
            Text(
              "We couldn't fetch catalogue inventory from the warehouse "
              'cluster right now.',
              textAlign: TextAlign.center,
              style: textTheme.bodyLarge,
            ),
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: onReload,
                icon: const Icon(Icons.refresh),
                label: const Text('Reload'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ProductRow extends StatelessWidget {
  const _ProductRow({required this.product, required this.onAdd});
  final Product product;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    // Below this, the item is close enough to selling out to say so —
    // matches the sku-2/sku-6 fixtures the tests read stock off of.
    final lowStock = product.inStock <= 5;

    // A Row rather than a ListTile: `trailing` holding both a price and a
    // button leaves the title almost no width, and at 411dp with the 1.35x
    // text scale it overflows. Expanded gives the text whatever is left.
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(NimbusTokens.radius),
              child: ProductImage(product, width: 56, height: 56),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    product.category,
                    style: textTheme.bodySmall
                        ?.copyWith(color: colorScheme.secondary),
                  ),
                  Text(
                    product.name,
                    style: textTheme.titleMedium,
                    overflow: TextOverflow.ellipsis,
                    maxLines: 2,
                  ),
                  const SizedBox(height: 4),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.star, size: 16, color: Colors.amber),
                      const SizedBox(width: 4),
                      Flexible(
                        child: Text(
                          product.rating.toStringAsFixed(1),
                          style: textTheme.bodyMedium,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          product.price,
                          style: textTheme.titleMedium,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (lowStock) ...[
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            'Only ${product.inStock} left',
                            style: textTheme.bodySmall
                                ?.copyWith(color: colorScheme.error),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: onAdd,
              style: FilledButton.styleFrom(
                minimumSize: const Size(80, 48),
                padding: const EdgeInsets.symmetric(horizontal: 12),
              ),
              child: const Text('Add'),
            ),
          ],
        ),
      ),
    );
  }
}
