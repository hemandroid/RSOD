import 'package:flutter/material.dart';
import '../../main.dart';
import '../../theme.dart';
import '../api.dart';

class ConfirmationScreen extends StatelessWidget {
  const ConfirmationScreen({super.key});

  // Mirrors checkout's fixed demo total and address so this screen never
  // states a different amount or delivery destination than the one the
  // customer just paid for.
  static const _totalPaise = 799900;
  static const _address = 'Flat 402, Green Glen Layout\nBellandur, Bengaluru 560103';

  @override
  Widget build(BuildContext context) {
    final paymentId = ModalRoute.of(context)?.settings.arguments as String?;
    final colors = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Order confirmed')),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Center(
            child: Column(
              children: [
                Container(
                  width: 88,
                  height: 88,
                  decoration: const BoxDecoration(
                    color: NimbusTokens.successGreen,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.check, color: Colors.white, size: 48),
                ),
                const SizedBox(height: 20),
                Text('Order confirmed', style: text.headlineSmall),
                const SizedBox(height: 8),
                Text(
                  "Thank you for your purchase. We've received your order "
                  'and are packing it up.',
                  textAlign: TextAlign.center,
                  style: text.bodyMedium,
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Text(
                          'PAYMENT REFERENCE',
                          style: text.labelLarge
                              ?.copyWith(color: NimbusTokens.secondary),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                          color: colors.surfaceContainer,
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          'PAID',
                          style: text.labelLarge
                              ?.copyWith(color: NimbusTokens.successGreen),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: colors.surfaceContainer,
                      borderRadius: BorderRadius.circular(NimbusTokens.radius),
                    ),
                    child: Text(
                      paymentId ?? 'unknown',
                      style: text.titleMedium?.copyWith(letterSpacing: 1),
                    ),
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
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Text('Total Paid',
                            style: text.titleMedium,
                            overflow: TextOverflow.ellipsis),
                      ),
                      const SizedBox(width: 12),
                      Text(rupees(_totalPaise), style: text.headlineSmall),
                    ],
                  ),
                  const Divider(height: 28),
                  _infoRow(
                    context,
                    icon: Icons.schedule,
                    label: 'ESTIMATED DELIVERY',
                    // Same window quoted at checkout — this screen can't
                    // promise a different one.
                    value: 'Tomorrow by 8:00 PM',
                    caption: 'Priority Air Express',
                  ),
                  const SizedBox(height: 16),
                  _infoRow(
                    context,
                    icon: Icons.pin_drop,
                    label: 'DELIVERY TO',
                    value: _address,
                  ),
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: colors.surfaceContainer,
                      borderRadius: BorderRadius.circular(NimbusTokens.radius),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.inventory_2, color: colors.primary),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('1 item dispatched', style: text.titleMedium),
                              Text('Denim Jacket', style: text.bodyMedium),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: () {
              Navigator.popUntil(context, (route) => route.isFirst);
              shellTab.value = 0;
            },
            icon: const Icon(Icons.storefront),
            label: const Text('Back to store'),
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 18),
            ),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: () {
              Navigator.popUntil(context, (route) => route.isFirst);
              shellTab.value = 2;
            },
            icon: const Icon(Icons.receipt_long),
            label: const Text('View order receipt'),
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 16),
              minimumSize: const Size.fromHeight(48),
            ),
          ),
        ],
      ),
    );
  }

  Widget _infoRow(
    BuildContext context, {
    required IconData icon,
    required String label,
    required String value,
    String? caption,
  }) {
    final colors = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            color: colors.surfaceContainer,
            borderRadius: BorderRadius.circular(NimbusTokens.radius),
          ),
          child: Icon(icon, color: colors.primary),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label,
                  style:
                      text.labelLarge?.copyWith(color: NimbusTokens.secondary)),
              Text(value, style: text.titleMedium),
              if (caption != null)
                Text(caption,
                    style: text.labelLarge
                        ?.copyWith(color: NimbusTokens.successGreen)),
            ],
          ),
        ),
      ],
    );
  }
}
