import 'package:flutter/material.dart';

/// Cycling avatar palette shared by the boot-time profile picker and the
/// channel list's AppBar avatar.
const kProfileAvatarColors = [
  Color(0xFF2D6BE4),
  Color(0xFFE34040),
  Color(0xFF2DBE8C),
  Color(0xFFE87C26),
  Color(0xFF8B5CF6),
  Color(0xFFE84393),
];

Color profileAvatarColor(int colorIndex) =>
    kProfileAvatarColors[colorIndex % kProfileAvatarColors.length];

/// Stable palette slot for a cloud profile, derived from its id so the colour
/// doesn't shift when the account's profile list is reordered. (Local profiles
/// store an explicit colorIndex instead.)
int profileColorIndexFor(String id) {
  var h = 0;
  for (final c in id.codeUnits) {
    h = (h * 31 + c) & 0x7fffffff;
  }
  return h % kProfileAvatarColors.length;
}

enum _ProfileMenuAction { changeProfile, profileSettings }

/// The AppBar avatar: the active profile's initial in its colour, opening a
/// dropdown with "Change profile" and (when wired) "Profile settings".
class ProfileAvatarButton extends StatelessWidget {
  final String? profileName;
  final int colorIndex;
  final VoidCallback? onChangeProfile;
  final VoidCallback? onProfileSettings;

  const ProfileAvatarButton({
    super.key,
    required this.profileName,
    required this.colorIndex,
    required this.onChangeProfile,
    required this.onProfileSettings,
  });

  @override
  Widget build(BuildContext context) {
    final name = (profileName?.isNotEmpty == true) ? profileName! : null;
    final initial = name != null ? name[0].toUpperCase() : null;
    final color = profileAvatarColor(colorIndex);

    return PopupMenuButton<_ProfileMenuAction>(
      tooltip: name ?? 'Profile',
      offset: const Offset(0, 48),
      onSelected: (action) {
        switch (action) {
          case _ProfileMenuAction.changeProfile:
            onChangeProfile?.call();
          case _ProfileMenuAction.profileSettings:
            onProfileSettings?.call();
        }
      },
      itemBuilder: (_) => [
        if (onChangeProfile != null)
          const PopupMenuItem(
            value: _ProfileMenuAction.changeProfile,
            child: Row(
              children: [
                Icon(Icons.switch_account_outlined, size: 18),
                SizedBox(width: 10),
                Text('Change profile'),
              ],
            ),
          ),
        if (onProfileSettings != null)
          const PopupMenuItem(
            value: _ProfileMenuAction.profileSettings,
            child: Row(
              children: [
                Icon(Icons.cloud_sync_outlined, size: 18),
                SizedBox(width: 10),
                Text('Profile settings'),
              ],
            ),
          ),
      ],
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: CircleAvatar(
          radius: 16,
          backgroundColor: color,
          child: initial != null
              ? Text(
                  initial,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                )
              : const Icon(Icons.person_outline, color: Colors.white, size: 18),
        ),
      ),
    );
  }
}
