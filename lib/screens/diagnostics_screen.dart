import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/diagnostics_log.dart';
import '../theme.dart';

class DiagnosticsScreen extends StatelessWidget {
  const DiagnosticsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final log = DiagnosticsLog.instance;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Diagnostics'),
        actions: [
          IconButton(
            tooltip: 'Copy',
            icon: const Icon(Icons.copy_outlined),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: log.asText()));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Diagnostics copied')),
              );
            },
          ),
          IconButton(
            tooltip: 'Clear',
            icon: const Icon(Icons.delete_outline),
            onPressed: log.clear,
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: AnimatedBuilder(
        animation: log,
        builder: (context, _) {
          final entries = log.entries.reversed.toList();
          if (entries.isEmpty) {
            return const Center(
              child: Text(
                'No diagnostics yet',
                style: TextStyle(color: AppColors.textLo),
              ),
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.all(12),
            itemCount: entries.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final entry = entries[index];
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: SelectableText(
                  '${_time(entry.time)}  ${entry.scope}\n${entry.message}',
                  style: const TextStyle(
                    color: AppColors.textLo,
                    fontSize: 12,
                    height: 1.35,
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }

  String _time(DateTime time) =>
      '${time.hour.toString().padLeft(2, '0')}:'
      '${time.minute.toString().padLeft(2, '0')}:'
      '${time.second.toString().padLeft(2, '0')}';
}
