import 'dart:async';
import 'package:flutter/material.dart';
import '../../main.dart';
import '../api.dart';
import '../../theme.dart';

class OrdersScreen extends StatefulWidget {
  const OrdersScreen({super.key});
  @override
  State<OrdersScreen> createState() => _OrdersScreenState();
}

class _OrdersScreenState extends State<OrdersScreen> {
  late Future<List<Order>> _orders = api.orders();

  /// This screen's slot in NimbusShell's tab bar.
  static const _tabIndex = 2;

  // NimbusShell's IndexedStack builds every tab at launch, so a list fetched
  // once would predate anything armed in the Chaos panel afterwards — the
  // duplicate-orders fault could never fire on stage. Refetch on every visit.
  @override
  void initState() {
    super.initState();
    shellTab.addListener(_onTabChanged);
  }

  @override
  void dispose() {
    shellTab.removeListener(_onTabChanged);
    super.dispose();
  }

  void _onTabChanged() {
    if (shellTab.value != _tabIndex) return;
    // Block body, not `=>`: an arrow would return the assigned Future and
    // setState rejects a callback that returns one.
    setState(() {
      _orders = api.orders();
    });
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    // No bottomNavigationBar here: the shell (NimbusShell) already supplies
    // one around the IndexedStack this screen lives in.
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
              Text(
                '${orders.length} shipments logged in this account',
                style: text.bodyMedium,
              ),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: NimbusTokens.sensitiveSurface,
                  borderRadius: BorderRadius.circular(NimbusTokens.radius),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.info,
                        color: NimbusTokens.sensitiveBorder, size: 24),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Stage Diagnostic Active',
                            style: text.labelLarge
                                ?.copyWith(color: NimbusTokens.primary),
                          ),
                          Text(
                            'Tap any shipment card or tracking trigger to '
                            'launch the real-time status tracker.',
                            style: text.bodyMedium,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              for (final order in orders)
                _OrderCard(
                  order: order,
                  // Duplicate ids are a live fault: flag it before the tap
                  // handler below hits it.
                  isDuplicate:
                      orders.where((o) => o.id == order.id).length > 1,
                  onTrack: () =>
                      Navigator.pushNamed(context, '/tracking'),
                  onTap: () {
                    // Looking the order back up by id: `singleWhere` throws
                    // when a retried write has left two rows with the same
                    // id.
                    final found =
                        orders.singleWhere((o) => o.id == order.id);
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Order ${found.id}')),
                    );
                  },
                ),
            ],
          );
        },
      ),
    );
  }
}

class _OrderCard extends StatelessWidget {
  const _OrderCard({
    required this.order,
    required this.isDuplicate,
    required this.onTrack,
    required this.onTap,
  });

  final Order order;
  final bool isDuplicate;
  final VoidCallback onTrack;
  final VoidCallback onTap;

  /// Five statuses on the wire now, not two — a flat delivered/not-delivered
  /// split would paint Cancelled the same green as Delivered.
  Color _statusColor() {
    switch (order.status) {
      case 'Delivered':
        return NimbusTokens.successGreen;
      case 'In transit':
        return NimbusTokens.primary;
      case 'Out for delivery':
        return Colors.orange.shade800;
      case 'Cancelled':
        return NimbusTokens.error;
      case 'Processing':
      default:
        return NimbusTokens.secondary;
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final statusColor = _statusColor();
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(NimbusTokens.radius * 1.5),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(NimbusTokens.radius),
                    child: Image.asset(
                      order.imageAsset,
                      width: 56,
                      height: 56,
                      fit: BoxFit.cover,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                '#${order.id}',
                                overflow: TextOverflow.ellipsis,
                                style: text.titleMedium,
                              ),
                            ),
                            if (isDuplicate) ...[
                              const SizedBox(width: 6),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 6, vertical: 2),
                                decoration: BoxDecoration(
                                  color: NimbusTokens.chaosSurface,
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: const Text(
                                  'DUP',
                                  style: TextStyle(
                                    color: NimbusTokens.chaosAmber,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 12,
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                        const SizedBox(height: 2),
                        Text(
                          order.summary,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: text.bodyLarge,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          order.placedOn,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: text.bodyMedium,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  // Bounded: "Out for delivery" is far wider than "Delivered",
                  // and an unbounded trailing column pushes the row over.
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 124),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(rupees(order.paise), style: text.titleMedium),
                        const SizedBox(height: 4),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(
                            color: colors.surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Text(
                            order.status,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.end,
                            style:
                                text.labelLarge?.copyWith(color: statusColor),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const Divider(height: 20),
              Row(
                children: [
                  Icon(Icons.local_shipping_outlined,
                      size: 18, color: colors.secondary),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      order.courier,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: text.bodyMedium,
                    ),
                  ),
                  IconButton(
                    tooltip: 'Track shipment',
                    visualDensity: VisualDensity.compact,
                    style: IconButton.styleFrom(
                      backgroundColor: colors.secondaryContainer,
                      foregroundColor: colors.primary,
                    ),
                    icon: const Icon(Icons.gps_fixed, size: 18),
                    onPressed: onTrack,
                  ),
                ],
              ),
              if (isDuplicate) ...[
                const Divider(height: 20),
                Row(
                  children: [
                    const Icon(Icons.sync_problem,
                        size: 18, color: NimbusTokens.chaosAmber),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        'Duplicate state trigger ready',
                        style: text.labelLarge
                            ?.copyWith(color: NimbusTokens.chaosAmber),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Icon(Icons.chevron_right, color: colors.primary),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
