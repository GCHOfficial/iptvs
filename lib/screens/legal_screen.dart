import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../data/app_links.dart';
import '../theme.dart';

class LegalScreen extends StatelessWidget {
  const LegalScreen({super.key});

  Future<void> _open(BuildContext context, String value) async {
    final opened = await launchUrl(
      Uri.parse(value),
      mode: LaunchMode.externalApplication,
    );
    if (!opened && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not open the web page.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Privacy & support')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'IPTVS Player works without an account. Cloud sync is optional and '
            'is managed through the web panel.',
            style: TextStyle(color: AppColors.textLo),
          ),
          const SizedBox(height: 16),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.privacy_tip_outlined),
            title: const Text('Privacy policy'),
            subtitle: const Text('What the app stores and sends'),
            trailing: const Icon(Icons.open_in_new),
            onTap: () => _open(context, AppLinks.privacyPolicy),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.help_outline),
            title: const Text('Support'),
            subtitle: const Text('Troubleshooting and contact information'),
            trailing: const Icon(Icons.open_in_new),
            onTap: () => _open(context, AppLinks.support),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.delete_outline),
            title: const Text('Delete cloud account'),
            subtitle: const Text(
              'Permanently remove an optional panel account and its cloud data',
            ),
            trailing: const Icon(Icons.open_in_new),
            onTap: () => _open(context, AppLinks.deleteCloudAccount),
          ),
        ],
      ),
    );
  }
}
