import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

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
      final metadata = await _sync.pullMetadata(widget.store);
      if (!mounted) return;
      final sources = 'Synced $count source${count == 1 ? '' : 's'}';
      setState(() => _status = '${initial ? 'Paired — ' : ''}$sources'
          '${metadata ? ' · metadata updated' : ''}.');
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _copyCode() async {
    final code = _code?.code;
    if (code == null) return;
    await Clipboard.setData(ClipboardData(text: code));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Code copied'), duration: Duration(seconds: 2)),
    );
  }

  Future<void> _openPanel() async {
    final uri = Uri.tryParse(CloudConfig.panelUrl);
    var ok = false;
    if (uri != null) {
      try {
        ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      } catch (_) {
        ok = false;
      }
    }
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Couldn\'t open the link — visit it manually')),
      );
    }
  }

  Future<void> _push() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Push to panel?'),
        content: const Text(
          'This replaces the source list and metadata settings in the panel '
          'with the ones on this device. Anything in the panel that isn\'t on '
          'this device will be removed.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Push'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() {
      _busy = true;
      _error = null;
      _status = null;
    });
    try {
      final count = await _sync.pushSources(widget.store);
      await _sync.pushMetadata(widget.store);
      if (!mounted) return;
      setState(() => _status =
          'Pushed $count source${count == 1 ? '' : 's'} · metadata to the panel.');
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
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: InkWell(
              onTap: _code == null ? null : _copyCode,
              borderRadius: BorderRadius.circular(12),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 18,
                ),
                decoration: BoxDecoration(
                  color: AppColors.panelHi,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    // Balances the trailing copy icon so the code stays centered.
                    const SizedBox(width: 38),
                    // Scale the code down so any glyph mix fits the box on a
                    // narrow phone instead of overflowing.
                    Expanded(
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.center,
                        child: Text(
                          _code?.code ?? '········',
                          maxLines: 1,
                          style: const TextStyle(
                            fontSize: 40,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 8,
                            fontFeatures: [FontFeature.tabularFigures()],
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 14),
                    const Icon(Icons.copy_rounded, color: AppColors.textLo),
                  ],
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        const Center(
          child: Text(
            'Tap the code to copy it',
            style: TextStyle(color: AppColors.textLo, fontSize: 12),
          ),
        ),
        const SizedBox(height: 16),
        Center(
          child: InkWell(
            onTap: _openPanel,
            borderRadius: BorderRadius.circular(6),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.open_in_new, size: 16, color: AppColors.accent),
                  const SizedBox(width: 6),
                  Text(
                    CloudConfig.panelUrl,
                    style: const TextStyle(
                      color: AppColors.accent,
                      decoration: TextDecoration.underline,
                      decorationColor: AppColors.accent,
                    ),
                  ),
                ],
              ),
            ),
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
          'Sync this device with the panel. Pull replaces the cloud-managed '
          'sources and metadata here with the panel\'s (sources you added '
          'locally are kept). Push sends this device\'s list and metadata up, '
          'replacing the panel\'s. Newest change wins.',
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
          onPressed: _busy ? null : _push,
          icon: const Icon(Icons.cloud_upload_outlined),
          label: const Text('Push to panel'),
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: _busy ? null : _unpair,
          icon: const Icon(Icons.link_off),
          label: const Text('Unpair this device'),
        ),
      ];
}
