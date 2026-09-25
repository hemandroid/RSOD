import 'package:flutter/material.dart';
import '../../theme.dart';

// The fault switches and diagnostic actions that used to live here moved to
// the Chaos panel — this screen is ordinary storefront settings again, and
// nothing on it needs to be wired to real state.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _pushNotifications = true;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 28,
                    backgroundColor: colors.primaryContainer,
                    child: Icon(Icons.person, color: colors.onPrimary, size: 28),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text('Alex Morgan',
                                  overflow: TextOverflow.ellipsis,
                                  style: text.titleLarge),
                            ),
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 2),
                              decoration: BoxDecoration(
                                color: colors.secondaryContainer,
                                borderRadius: BorderRadius.circular(999),
                              ),
                              child: const Text(
                                'PRIMARY',
                                style: TextStyle(
                                    fontSize: 11, fontWeight: FontWeight.bold),
                              ),
                            ),
                          ],
                        ),
                        Text('alex.developer@example.com',
                            style: text.bodyMedium),
                        Text('Nimbus Verified Member',
                            style: text.labelLarge
                                ?.copyWith(color: colors.primary)),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: 'Edit profile',
                    icon: const Icon(Icons.edit),
                    onPressed: () {},
                  ),
                ],
              ),
            ),
          ),
          _section(context, 'Preferences', [
            SwitchListTile(
              secondary: Icon(Icons.notifications_active, color: colors.primary),
              title: const Text('Push notifications'),
              subtitle: const Text('Order updates & delivery alerts'),
              value: _pushNotifications,
              onChanged: (v) => setState(() => _pushNotifications = v),
            ),
            ListTile(
              leading: Icon(Icons.payments, color: colors.primary),
              title: const Text('Display currency'),
              subtitle: const Text('₹ INR (Indian Rupee)'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () {},
            ),
          ]),
          _section(context, 'Account & Delivery', [
            ListTile(
              leading: Icon(Icons.location_on, color: colors.primary),
              title: const Text('Default delivery address'),
              subtitle: const Text(
                  'Flat 402, Green Glen Layout, Bengaluru 560103'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () {},
            ),
            ListTile(
              leading: Icon(Icons.account_balance_wallet, color: colors.primary),
              title: const Text('Payment methods'),
              subtitle: const Text('Saved cards & UPI handles'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () {},
            ),
            ListTile(
              leading: Icon(Icons.manage_accounts, color: colors.primary),
              title: const Text('Nimbus account'),
              subtitle: const Text('alex.developer@example.com'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () {},
            ),
          ]),
          _section(context, 'Information', [
            ListTile(
              leading: Icon(Icons.info, color: colors.primary),
              title: const Text('About Nimbus Store'),
              subtitle: const Text('Version 2.14.0 (Production Build)'),
              trailing: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: colors.secondaryContainer,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: const Text('STABLE',
                    style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
              ),
            ),
            ListTile(
              leading: Icon(Icons.policy, color: colors.primary),
              title: const Text('Privacy policy & terms'),
              subtitle: const Text('Legal obligations & user privacy rights'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () {},
            ),
          ]),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: () {},
            icon: Icon(Icons.logout, color: colors.error),
            label: Text('Sign out of all sessions',
                style: TextStyle(color: colors.error, fontWeight: FontWeight.bold)),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size.fromHeight(52),
              side: BorderSide(color: colors.error),
            ),
          ),
          const SizedBox(height: 12),
          Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.verified_user,
                    size: 18, color: NimbusTokens.successGreen),
                const SizedBox(width: 6),
                Text('256-bit SSL Protected Retail Session',
                    style: text.labelLarge),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _section(BuildContext context, String title, List<Widget> tiles) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 8),
            child: Text(
              title.toUpperCase(),
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(color: colors.primary),
            ),
          ),
          Card(
            margin: EdgeInsets.zero,
            child: Column(
              children: [
                for (var i = 0; i < tiles.length; i++) ...[
                  if (i > 0) const Divider(height: 1),
                  tiles[i],
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
