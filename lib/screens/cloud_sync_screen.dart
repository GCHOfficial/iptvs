import 'dart:async';

import 'package:flutter/material.dart';

import '../data/cloud_config.dart';
import '../data/cloud_sync.dart';
import '../data/source_store.dart';
import '../theme.dart';

/// Pairs this device with a web-panel account and pulls its source list down.
/// No login happens here: the device shows a short code, the user enters it in
/// the panel (on a real keyboard), and this screen polls until it's claimed.
class CloudSyncScreen extends StatefulWidget {
  final SourceStore store;

  /// Inject a fake in tests; defaults to the live Supabase-backed [CloudSync].
  final CloudSync? sync;

  const CloudSyncScreen({super.key, required this.store, this.sync});

  @override
  State<CloudSyncScreen> createState() => _CloudSyncScreenState();
}

class _CloudSyncScreenState extends State<CloudSyncScreen> {
  late final CloudSync _sync = widget.sync ?? CloudSync();

  bool _loading = true;
  bool _paired = false;
  bool _busy = false;
  String? _error;
  String? _status;
  PairingCode? _code;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _init() async {
    try {
      await _sync.ensureAnonSession();
      if (await _sync.isPaired()) {
        if (mounted) setState(() => _paired = true);
      } else {
        await _newCode();
      }
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _newCode() async {
    _poll?.cancel();
    final code = await _sync.requestPairingCode();
    if (!mounted) return;
    setState(() {
      _code = code;
      _error = null;
    });
    _poll = Timer.periodic(const Duration(seconds: 3), (_) => _checkClaim());
  }

  Future<void> _checkClaim() async {
    final code = _code;
    if (code == null) return;
    // Codes are short-lived; refresh once expired so the screen stays usable.
    if (DateTime.now().isAfter(code.expiresAt)) {
      try {
        await _newCode();
      } catch (_) {/* keep polling on the old code's failure */}
      return;
    }
    try {
      if (await _sync.pairingStatus(code.code)) {
        _poll?.cancel();
        if (!mounted) return;
        setState(() => _paired = true);
        await _pull(initial: true);
      }
    } catch (_) {
      // Transient network error — the next tick retries.
    }
  }

  Future<void> _pull({bool initial = false}) async {
    setState(() {
      _busy = true;
      _error = null;
      _status = null;
    });
    try {
      final count = await _sync.pullSources(widget.store);
      await _sync.pullMetadata(widget.store);
      if (!mounted) return;
      setState(() => _status =
          '${initial ? 'Paired — ' : ''}Synced $count source${count == 1 ? '' : 's'}.');
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _unpair() async {
    setState(() => _busy = true);
    try {
      await _sync.unpair(widget.store);
      if (!mounted) return;
      setState(() {
        _paired = false;
        _status = null;
      });
      await _newCode();
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Cloud sync')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (_paired) ..._pairedBody() else ..._pairingBody(),
                  if (_status != null) ...[
                    const SizedBox(height: 20),
                    Text(
                      _status!,
                      style: const TextStyle(color: AppColors.accent),
                    ),
                  ],
                  if (_error != null) ...[
                    const SizedBox(height: 20),
                    Text(
                      _error!,
                      style: const TextStyle(color: Color(0xFFE5484D)),
                    ),
                  ],
                ],
              ),
            ),
    );
  }

  List<Widget> _pairingBody() => [
        const Text(
          'Pair this device',
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        Text(
          'Open the panel on your phone or computer, sign in, and enter this '
          'code under Devices:',
          style: const TextStyle(color: AppColors.textLo),
        ),
        const SizedBox(height: 20),
        Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 18),
            decoration: BoxDecoration(
              color: AppColors.panelHi,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              _code?.code ?? '········',
              style: const TextStyle(
                fontSize: 40,
                fontWeight: FontWeight.w700,
                letterSpacing: 8,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ),
        const SizedBox(height: 16),
        Center(
          child: Text(
            CloudConfig.panelUrl,
            style: const TextStyle(color: AppColors.textLo),
          ),
        ),
        const SizedBox(height: 24),
        FilledButton.icon(
          onPressed: _busy ? null : _newCode,
          icon: const Icon(Icons.refresh),
          label: const Text('New code'),
        ),
      ];

  List<Widget> _pairedBody() => [
        Row(
          children: const [
            Icon(Icons.cloud_done_outlined, color: AppColors.accent),
            SizedBox(width: 10),
            Text(
              'This device is paired',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
            ),
          ],
        ),
        const SizedBox(height: 8),
        const Text(
          'Your sources are managed from the panel. Pull to apply the latest '
          'list to this device.',
          style: TextStyle(color: AppColors.textLo),
        ),
        const SizedBox(height: 24),
        FilledButton.icon(
          onPressed: _busy ? null : () => _pull(),
          icon: _busy
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.sync),
          label: const Text('Pull now'),
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: _busy ? null : _unpair,
          icon: const Icon(Icons.link_off),
          label: const Text('Unpair this device'),
        ),
      ];
}
