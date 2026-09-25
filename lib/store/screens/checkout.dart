import 'dart:async';
import 'package:flutter/material.dart';
import 'package:incident_sdk/incident_sdk.dart';
import '../../main.dart';
import '../../theme.dart';

class CheckoutScreen extends StatefulWidget {
  const CheckoutScreen({super.key});
  @override
  State<CheckoutScreen> createState() => _CheckoutScreenState();
}

class _CheckoutScreenState extends State<CheckoutScreen> {
  bool _busy = false;

  // The total is the only real number on this screen; every breakdown line
  // below is derived from it so none of them can contradict each other or
  // the amount `_pay` actually charges.
  static const _totalPaise = 799900;
  static const _platformFeePaise = 20000;
  static const _subtotalPaise = _totalPaise - _platformFeePaise;

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
    final colors = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Checkout')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
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
                          'TOTAL PAYABLE',
                          style: text.labelLarge
                              ?.copyWith(color: NimbusTokens.textMedium),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: colors.secondaryContainer,
                          borderRadius:
                              BorderRadius.circular(NimbusTokens.radius),
                        ),
                        child: Text('1 item', style: text.labelLarge),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Flexible(
                        child: Text(_rupees(_totalPaise),
                            style: text.headlineMedium,
                            overflow: TextOverflow.ellipsis),
                      ),
                      const SizedBox(width: 8),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.verified,
                              color: NimbusTokens.successGreen, size: 20),
                          const SizedBox(width: 4),
                          Text(
                            'Best Price',
                            style: text.labelLarge
                                ?.copyWith(color: NimbusTokens.successGreen),
                          ),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      Icon(Icons.local_shipping, color: colors.primary, size: 20),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Guaranteed express delivery by tomorrow, 8:00 PM',
                          style: text.bodyMedium,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          _sensitiveDetails(context),
          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Price Breakup', style: text.titleMedium),
                  const SizedBox(height: 12),
                  _priceRow(context, 'Items Subtotal (1)', _rupees(_subtotalPaise)),
                  const SizedBox(height: 10),
                  _priceRow(context, 'Standard Logistics', 'Free',
                      valueColor: NimbusTokens.successGreen),
                  const SizedBox(height: 10),
                  _priceRow(
                      context, 'Platform & Handling', _rupees(_platformFeePaise)),
                  const Divider(height: 28),
                  _priceRow(context, 'Final Amount', _rupees(_totalPaise),
                      emphasize: true),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 16,
            runSpacing: 8,
            children: [
              _trustBadge(context, Icons.lock_clock, '256-bit SSL'),
              _trustBadge(context, Icons.assured_workload, 'RBI Compliant'),
              _trustBadge(context, Icons.autorenew, 'Instant Refund'),
            ],
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _busy ? null : _pay,
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 22),
            ),
            child: _busy
                ? const Text('Contacting bank…')
                : Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.lock_open, size: 22),
                      const SizedBox(width: 8),
                      Text('Pay ${_rupees(_totalPaise)} now'),
                    ],
                  ),
          ),
          const SizedBox(height: 12),
          Center(
            child: Text(
              'Nimbus Commerce Node #IND-BLR-09 • Auto-masked on snapshot',
              textAlign: TextAlign.center,
              style: text.labelLarge?.copyWith(color: NimbusTokens.secondary),
            ),
          ),
        ],
      ),
    );
  }

  // The block the SDK paints over before a screenshot ships. It has to read
  // as one deliberate unit — heading, badge and notice all inside the same
  // bordered surface — so the redaction never looks like a rendering fault.
  Widget _sensitiveDetails(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: NimbusTokens.sensitiveSurface,
        borderRadius: BorderRadius.circular(NimbusTokens.radius * 1.5),
        border: Border.all(color: NimbusTokens.sensitiveBorder, width: 2),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: colors.primaryContainer,
                  borderRadius: BorderRadius.circular(NimbusTokens.radius),
                ),
                child: Icon(Icons.lock, color: colors.onPrimary, size: 20),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Payment & Delivery Details', style: text.titleMedium),
                    Text(
                      'PROTECTED REDACTION ZONE',
                      style: text.labelLarge
                          ?.copyWith(color: colors.primary, letterSpacing: 1),
                    ),
                  ],
                ),
              ),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: colors.primary,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.shield, size: 14, color: colors.onPrimary),
                    const SizedBox(width: 4),
                    Text(
                      'PCI-DSS',
                      style: TextStyle(
                        color: colors.onPrimary,
                        fontWeight: FontWeight.bold,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Divider(color: NimbusTokens.sensitiveBorder.withValues(alpha: 0.3)),
          const SizedBox(height: 12),
          // Card and address are real user data, so they never reach a
          // screenshot.
          IncidentMask(
            child: Column(
              children: const [
                TextField(
                  decoration: InputDecoration(
                    labelText: 'Card number',
                    filled: true,
                    fillColor: Colors.white,
                  ),
                ),
                SizedBox(height: 16),
                TextField(
                  decoration: InputDecoration(
                    labelText: 'Address',
                    filled: true,
                    fillColor: Colors.white,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Icon(Icons.privacy_tip, size: 18, color: colors.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Hardware token & screen capture masking enabled',
                  style: text.labelLarge,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _priceRow(BuildContext context, String label, String value,
      {Color? valueColor, bool emphasize = false}) {
    final text = Theme.of(context).textTheme;
    final labelStyle = emphasize ? text.titleLarge : text.bodyMedium;
    final valueStyle = (emphasize ? text.titleLarge : text.bodyMedium)
        ?.copyWith(color: valueColor, fontWeight: FontWeight.bold);
    // Expanded on the label: "Platform & Handling" plus an amount does not
    // fit on one 411dp line once the 1.35x text scale is applied.
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Expanded(
          child:
              Text(label, style: labelStyle, overflow: TextOverflow.ellipsis),
        ),
        const SizedBox(width: 12),
        Text(value, style: valueStyle),
      ],
    );
  }

  Widget _trustBadge(BuildContext context, IconData icon, String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 18, color: NimbusTokens.secondary),
        const SizedBox(width: 4),
        Text(
          label,
          style: Theme.of(context)
              .textTheme
              .labelLarge
              ?.copyWith(color: NimbusTokens.secondary),
        ),
      ],
    );
  }
}

// Local formatter: `rupees()` in api.dart doesn't group digits, and the
// design's breakdown needs to read like real currency.
String _rupees(int paise) {
  final whole = (paise / 100).round().toString();
  final buffer = StringBuffer();
  for (var i = 0; i < whole.length; i++) {
    if (i > 0 && (whole.length - i) % 3 == 0) buffer.write(',');
    buffer.write(whole[i]);
  }
  return '₹$buffer';
}
