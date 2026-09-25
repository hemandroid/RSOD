import 'dart:async';
import 'package:flutter/material.dart';
import 'package:incident_sdk/incident_sdk.dart';
import '../../main.dart';
import '../api.dart';
import '../../theme.dart';

/// Replaces the old Settings screen as a shell tab: same fault switches, same
/// two instant triggers, now painted in the `chaos*` palette so it can never
/// be mistaken for part of the store on stage.
class ChaosPanelScreen extends StatefulWidget {
  const ChaosPanelScreen({super.key});
  @override
  State<ChaosPanelScreen> createState() => _ChaosPanelScreenState();
}

class _ChaosPanelScreenState extends State<ChaosPanelScreen> {
  // Copied verbatim from the settings screen this replaces. The
  // IncidentSDK.log calls are breadcrumbs the incident analyser reads, not
  // decoration — moving this behaviour means moving them too.

  /// Rebuilding the local index on the main thread. Fine for a few hundred
  /// orders in testing, not for a year of them.
  void _rebuildIndex() {
    IncidentSDK.log('chaos: rebuilding local index');
    final sink = StringBuffer();
    final until = DateTime.now().add(const Duration(seconds: 7));
    while (DateTime.now().isBefore(until)) {
      sink.write(DateTime.now().microsecondsSinceEpoch.toString());
      if (sink.length > 2000000) sink.clear();
    }
  }

  void _syncInBackground() {
    IncidentSDK.log('chaos: background sync started');
    unawaited(Future<void>(() async {
      await Future<void>.delayed(const Duration(milliseconds: 150));
      throw const StoreApiException('background sync: token refresh failed');
    }));
  }

  int get _armedCount => [
        faults.emptyCatalogue,
        faults.duplicateOrders,
        faults.expiredSession,
        faults.paymentApiDown,
        faults.missingRemoteFlag,
      ].where((armed) => armed).length;

  void _disarmAll() {
    setState(() {
      faults.emptyCatalogue = false;
      faults.duplicateOrders = false;
      faults.expiredSession = false;
      faults.paymentApiDown = false;
      faults.missingRemoteFlag = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Scaffold(
      backgroundColor: NimbusTokens.chaosBg,
      appBar: AppBar(
        backgroundColor: NimbusTokens.chaosBg,
        foregroundColor: NimbusTokens.chaosTextPrimary,
        elevation: 0,
        // The theme's titleTextStyle carries the store's navy; on this dark
        // bar that renders navy-on-navy, so the colour is overridden here.
        titleTextStyle: Theme.of(context)
            .appBarTheme
            .titleTextStyle
            ?.copyWith(color: NimbusTokens.chaosTextPrimary),
        title: const Text('Chaos panel'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          _HeroCard(armedCount: _armedCount, textTheme: textTheme),
          const SizedBox(height: 28),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Text(
                  'ARMED FAULTS (NEXT RUN)',
                  style: textTheme.labelLarge?.copyWith(
                    color: NimbusTokens.chaosAmber,
                    letterSpacing: 1.0,
                  ),
                ),
              ),
              TextButton.icon(
                onPressed: _disarmAll,
                icon: const Icon(Icons.restart_alt,
                    color: NimbusTokens.chaosTextSecondary),
                label: Text('Disarm all',
                    style: textTheme.labelLarge
                        ?.copyWith(color: NimbusTokens.chaosTextSecondary)),
              ),
            ],
          ),
          const SizedBox(height: 8),
          _FaultToggle(
            title: 'Catalogue returns nothing',
            subtitle: 'Featured banner empty state & handled throw',
            value: faults.emptyCatalogue,
            textTheme: textTheme,
            onChanged: (v) => setState(() => faults.emptyCatalogue = v),
          ),
          _FaultToggle(
            title: 'Order history has duplicates',
            subtitle: 'Throws Bad state: Too many elements',
            value: faults.duplicateOrders,
            textTheme: textTheme,
            onChanged: (v) => setState(() => faults.duplicateOrders = v),
          ),
          _FaultToggle(
            title: 'Checkout session expired',
            subtitle: 'Dereferences null on server response during payment',
            value: faults.expiredSession,
            textTheme: textTheme,
            onChanged: (v) => setState(() => faults.expiredSession = v),
          ),
          _FaultToggle(
            title: 'Payment API down',
            subtitle: 'Live: aims the catalogue at a dead host · '
                'Mock: simulates HTTP 503',
            value: faults.paymentApiDown,
            textTheme: textTheme,
            onChanged: (v) => setState(() => faults.paymentApiDown = v),
          ),
          _FaultToggle(
            title: 'Remote flag missing',
            subtitle: 'Store casts a null flag to bool while building · '
                'red screen',
            value: faults.missingRemoteFlag,
            textTheme: textTheme,
            onChanged: (v) => setState(() => faults.missingRemoteFlag = v),
          ),
          const SizedBox(height: 24),
          Text(
            'TRIGGER NOW (INSTANT BLAST)',
            style: textTheme.labelLarge?.copyWith(
              color: NimbusTokens.chaosRed,
              letterSpacing: 1.0,
            ),
          ),
          const SizedBox(height: 8),
          _TriggerRow(
            icon: Icons.hourglass_disabled,
            accent: NimbusTokens.chaosRed,
            title: 'Rebuild local index',
            subtitle: 'Blocks UI thread for ~7 seconds (ANR simulation)',
            textTheme: textTheme,
            onTrigger: _rebuildIndex,
          ),
          _TriggerRow(
            icon: Icons.sync_problem,
            accent: NimbusTokens.chaosAmber,
            title: 'Sync in background',
            subtitle: 'Throws unhandled exception off main isolate',
            textTheme: textTheme,
            onTrigger: _syncInBackground,
          ),
          const SizedBox(height: 24),
          _StatusStrip(textTheme: textTheme),
        ],
      ),
    );
  }
}

class _HeroCard extends StatelessWidget {
  const _HeroCard({required this.armedCount, required this.textTheme});
  final int armedCount;
  final TextTheme textTheme;

  @override
  Widget build(BuildContext context) {
    final armed = armedCount > 0;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: NimbusTokens.chaosSurface,
        borderRadius: BorderRadius.circular(NimbusTokens.radius * 1.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.bolt,
                            color: NimbusTokens.chaosAmber, size: 20),
                        const SizedBox(width: 6),
                        Text(
                          'CHAOS MODE ACTIVE',
                          style: textTheme.labelLarge
                              ?.copyWith(color: NimbusTokens.chaosAmber),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text('Chaos panel',
                        style: textTheme.headlineSmall
                            ?.copyWith(color: NimbusTokens.chaosTextPrimary)),
                    Text('Fault injection & crash simulator',
                        style: textTheme.bodyMedium
                            ?.copyWith(color: NimbusTokens.chaosTextSecondary)),
                  ],
                ),
              ),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: (armed ? NimbusTokens.chaosRed : NimbusTokens.chaosBorder)
                      .withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  armed ? 'ARMED' : 'IDLE',
                  style: textTheme.labelLarge?.copyWith(
                    color: armed
                        ? NimbusTokens.chaosRed
                        : NimbusTokens.chaosTextSecondary,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.only(top: 12),
            decoration: const BoxDecoration(
              border: Border(
                top: BorderSide(color: NimbusTokens.chaosBorder),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Armed traps',
                    style: textTheme.labelLarge
                        ?.copyWith(color: NimbusTokens.chaosTextSecondary)),
                Text('$armedCount/5',
                    style: textTheme.headlineSmall
                        ?.copyWith(color: NimbusTokens.chaosAmber)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _FaultToggle extends StatelessWidget {
  const _FaultToggle({
    required this.title,
    required this.subtitle,
    required this.value,
    required this.textTheme,
    required this.onChanged,
  });

  final String title;
  final String subtitle;
  final bool value;
  final TextTheme textTheme;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: NimbusTokens.chaosSurface,
        borderRadius: BorderRadius.circular(NimbusTokens.radius * 1.5),
        child: InkWell(
          borderRadius: BorderRadius.circular(NimbusTokens.radius * 1.5),
          onTap: () => onChanged(!value),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title,
                          style: textTheme.titleMedium
                              ?.copyWith(color: NimbusTokens.chaosTextPrimary)),
                      Text(subtitle,
                          style: textTheme.bodyMedium?.copyWith(
                              color: NimbusTokens.chaosTextSecondary)),
                    ],
                  ),
                ),
                // Min 48dp tap target satisfied by the row padding above; the
                // switch itself just needs to read clearly at 1.35x scale.
                Switch(
                  value: value,
                  onChanged: onChanged,
                  activeThumbColor: NimbusTokens.chaosSurface,
                  activeTrackColor: NimbusTokens.chaosAmber,
                  inactiveThumbColor: NimbusTokens.chaosTextSecondary,
                  inactiveTrackColor: NimbusTokens.chaosBorder,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _TriggerRow extends StatelessWidget {
  const _TriggerRow({
    required this.icon,
    required this.accent,
    required this.title,
    required this.subtitle,
    required this.textTheme,
    required this.onTrigger,
  });

  final IconData icon;
  final Color accent;
  final String title;
  final String subtitle;
  final TextTheme textTheme;
  final VoidCallback onTrigger;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: NimbusTokens.chaosSurface,
          borderRadius: BorderRadius.circular(NimbusTokens.radius * 1.5),
        ),
        child: Row(
          children: [
            Container(
              width: 48,
              height: 48,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: accent.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(NimbusTokens.radius),
              ),
              child: Icon(icon, color: accent, size: 26),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: textTheme.titleMedium
                          ?.copyWith(color: NimbusTokens.chaosTextPrimary)),
                  Text(subtitle,
                      style: textTheme.bodyMedium
                          ?.copyWith(color: NimbusTokens.chaosTextSecondary)),
                ],
              ),
            ),
            const SizedBox(width: 12),
            FilledButton(
              onPressed: onTrigger,
              style: FilledButton.styleFrom(
                backgroundColor: accent,
                foregroundColor: NimbusTokens.chaosBg,
                minimumSize: const Size(72, 48),
                padding: const EdgeInsets.symmetric(horizontal: 16),
              ),
              child: const Text('Trigger'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Endpoint comes from the same `--dart-define` `IncidentSDK.init` reads in
/// main.dart — shown, not fabricated. The upload state to its right is a
/// static label, not a live signal: nothing in this app reports a successful
/// upload back to the device.
class _StatusStrip extends StatelessWidget {
  const _StatusStrip({required this.textTheme});
  final TextTheme textTheme;

  static const _endpoint = String.fromEnvironment('INCIDENT_ENDPOINT');

  String get _shortEndpoint {
    if (_endpoint.isEmpty) return 'not configured';
    final stripped =
        _endpoint.replaceFirst(RegExp(r'^https?://'), '');
    return stripped.length > 28 ? '${stripped.substring(0, 28)}…' : stripped;
  }

  bool get _isLocal =>
      _endpoint.contains('localhost') || _endpoint.contains('10.0.2.2');

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: NimbusTokens.chaosSurface,
        borderRadius: BorderRadius.circular(NimbusTokens.radius * 1.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Endpoint',
                  style: textTheme.bodyMedium
                      ?.copyWith(color: NimbusTokens.chaosTextSecondary)),
              Flexible(
                child: Text(
                  '$_shortEndpoint · ${_isLocal ? 'Local' : 'Cloud'}',
                  textAlign: TextAlign.right,
                  style: textTheme.titleMedium
                      ?.copyWith(color: NimbusTokens.chaosTextPrimary),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
