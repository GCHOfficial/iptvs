import 'package:flutter/material.dart';

import '../sources/source.dart';
import '../theme.dart';

class NowProgrammeOverlay extends StatelessWidget {
  final Programme programme;
  final Programme? nextProgramme;

  const NowProgrammeOverlay({
    super.key,
    required this.programme,
    this.nextProgramme,
  });

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppColors.panel.withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${_formatProgrammeTime(programme.start)} – ${_formatProgrammeTime(programme.stop)} · ${programme.title}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
            if (programme.description != null && programme.description!.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  programme.description!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppColors.textLo,
                    fontSize: 12,
                  ),
                ),
              ),
            if (nextProgramme != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  'Next: ${nextProgramme!.title} (${_formatProgrammeTime(nextProgramme!.start)} - ${_formatProgrammeTime(nextProgramme!.stop)})',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppColors.textLo,
                    fontSize: 12,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  static String _formatProgrammeTime(DateTime time) {
    final hours = time.hour.toString().padLeft(2, '0');
    final minutes = time.minute.toString().padLeft(2, '0');
    return '$hours:$minutes';
  }
}
