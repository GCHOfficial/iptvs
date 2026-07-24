import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../data/app_links.dart';
import '../data/update_service.dart' show appVersion;
import '../theme.dart';
import '../widgets/focusable_card.dart';

/// Help & about — reachable from the channel-list AppBar and the first-run
/// empty state. Intentionally link-based (no in-app feedback form, no
/// analytics): support and issue reporting live on the web / GitHub, in
/// keeping with the app being open-source.
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
      appBar: AppBar(title: const Text('Help & about')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'IPTVS Player is a free, open-source player for the IPTV sources you '
            'already have access to. It ships no channels — bring your own '
            'Stalker portal, Xtream account, or M3U playlist, or try the '
            'built-in Demo (no account needed). Cloud sync is optional.',
            style: TextStyle(color: AppColors.textLo),
          ),
          const SizedBox(height: 16),
          _LinkCard(
            icon: Icons.help_outline,
            title: 'Support',
            subtitle: 'Troubleshooting and contact information',
            onTap: () => _open(context, AppLinks.support),
          ),
          _LinkCard(
            icon: Icons.code,
            title: 'Source code & issues',
            subtitle: 'View the code or report a problem on GitHub',
            onTap: () => _open(context, AppLinks.repository),
          ),
          _LinkCard(
            icon: Icons.privacy_tip_outlined,
            title: 'Privacy policy',
            subtitle: 'What the app stores and sends',
            onTap: () => _open(context, AppLinks.privacyPolicy),
          ),
          _LinkCard(
            icon: Icons.delete_outline,
            title: 'Delete cloud account',
            subtitle:
                'Permanently remove an optional panel account and its cloud data',
            onTap: () => _open(context, AppLinks.deleteCloudAccount),
          ),
          const SizedBox(height: 20),
          const _VersionLine(),
        ],
      ),
    );
  }
}

/// A single D-pad-navigable link row (FocusableCard so the OK-ring convention
/// and "OK to activate" behaviour match the rest of the TV-facing UI).
class _LinkCard extends StatelessWidget {
  const _LinkCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return FocusableCard(
      onTap: onTap,
      scrollOnFocus: false,
      semanticsLabel: '$title. $subtitle. Opens in your browser.',
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: [
            Icon(icon, size: 22, color: AppColors.textLo),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: const TextStyle(
                      color: AppColors.textLo,
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            const Icon(Icons.open_in_new, size: 18, color: AppColors.textLo),
          ],
        ),
      ),
    );
  }
}

/// App version, read from package metadata. Useful in support requests; nothing
/// is sent anywhere.
class _VersionLine extends StatelessWidget {
  const _VersionLine();

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<String>(
      future: appVersion(),
      builder: (context, snapshot) {
        final version = snapshot.data;
        return Text(
          version == null ? 'IPTVS Player' : 'IPTVS Player $version',
          style: const TextStyle(color: AppColors.textLo, fontSize: 12),
        );
      },
    );
  }
}
