import 'package:flutter/material.dart';
import '../../main.dart';
import '../../theme.dart';

/// Pushed by main.dart's global error handlers whenever an unhandled error
/// reaches Flutter or the platform dispatcher. The Jira ticket the SDK files
/// for it happens asynchronously on the backend and never calls back to this
/// device, so this screen must never claim a ticket number or error code —
/// only that a report was sent.
class FailureScreen extends StatelessWidget {
  const FailureScreen({super.key});

  void _backToStore(BuildContext context) {
    shellTab.value = 0;
    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: NimbusTokens.chaosBg,
      appBar: AppBar(
        backgroundColor: NimbusTokens.chaosBg,
        foregroundColor: NimbusTokens.chaosTextPrimary,
        elevation: 0,
        // Same override as ChaosPanelScreen: the theme's titleTextStyle carries
        // the store's navy, which on this bar renders navy-on-navy.
        titleTextStyle: Theme.of(context)
            .appBarTheme
            .titleTextStyle
            ?.copyWith(color: NimbusTokens.chaosTextPrimary),
        automaticallyImplyLeading: false,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Nimbus Crash Recovery'),
            Text('Exception caught',
                style: textTheme.bodyMedium
                    ?.copyWith(color: NimbusTokens.chaosAmber)),
          ],
        ),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  children: [
                    Stack(
                      alignment: Alignment.center,
                      children: [
                        Container(
                          width: 96,
                          height: 96,
                          decoration: BoxDecoration(
                            color: colors.secondaryContainer,
                            shape: BoxShape.circle,
                          ),
                          child: Icon(Icons.cloud_off,
                              size: 48, color: colors.primaryContainer),
                        ),
                        Positioned(
                          bottom: 0,
                          right: 0,
                          child: Container(
                            width: 32,
                            height: 32,
                            decoration: BoxDecoration(
                              color: Theme.of(context).cardColor,
                              shape: BoxShape.circle,
                              boxShadow: const [
                                BoxShadow(
                                    color: Colors.black12, blurRadius: 4),
                              ],
                            ),
                            child: const Icon(Icons.check_circle,
                                size: 22, color: NimbusTokens.successGreen),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),
                    Text('Something went wrong',
                        textAlign: TextAlign.center,
                        style: textTheme.headlineMedium),
                    const SizedBox(height: 12),
                    Text(
                      "This has been reported to our engineering team "
                      "automatically. You don't need to do anything.",
                      textAlign: TextAlign.center,
                      style: textTheme.bodyLarge
                          ?.copyWith(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 20),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 10),
                      decoration: BoxDecoration(
                        color: NimbusTokens.sensitiveSurface,
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.check_circle,
                              size: 20, color: NimbusTokens.successGreen),
                          const SizedBox(width: 8),
                          Text('Diagnostics sent',
                              style: textTheme.labelLarge
                                  ?.copyWith(color: colors.primaryContainer)),
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: colors.surfaceContainerHighest,
                        borderRadius:
                            BorderRadius.circular(NimbusTokens.radius),
                      ),
                      child: Row(
                        children: [
                          CircleAvatar(
                            backgroundColor: Theme.of(context).cardColor,
                            child: Icon(Icons.lock_clock,
                                color: colors.primaryContainer),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('Cart preserved',
                                    style: textTheme.titleMedium),
                                Text('Your items remain safe',
                                    style: textTheme.bodyMedium),
                              ],
                            ),
                          ),
                          Icon(Icons.verified_user, color: colors.primary),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 28),
            FilledButton.icon(
              onPressed: () => _backToStore(context),
              icon: const Icon(Icons.storefront),
              label: const Text('Back to store'),
            ),
          ],
        ),
      ),
    );
  }
}
