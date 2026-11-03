import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../data/diagnostics_share_server.dart';
import '../theme.dart';

/// "Share on Wi-Fi" — the LAN fallback for getting a log off a television.
///
/// ## Why this exists at all
///
/// The cloud path needs a configured build and a working internet connection,
/// and the reports most worth collecting are the ones from a box whose network
/// is the problem. This hands the log over the local network instead: the
/// device binds a throwaway HTTP server on an ephemeral port behind an
/// unguessable path, and the user opens the URL on a phone that is already
/// sitting next to them.
///
/// ## What the user is told, and why
///
/// Two facts are stated plainly on screen rather than buried:
///
///   * **the phone must be on the same Wi-Fi** — this is the single failure
///     everyone hits, because a phone on mobile data looks connected and the
///     page simply never loads;
///   * **it is plain HTTP, so anyone on the same network could read it while
///     it is open.** There is no certificate a device can present for its own
///     LAN IP, so the honest answer is to say so and keep the window short
///     rather than to imply a protection that is not there.
///
/// ## Lifetime
///
/// The server runs only while this route is on screen, for at most
/// [DiagnosticsShareServer.maxLifetime], and stops on dispose **and** on the
/// app leaving the foreground. A share left running behind a backgrounded app
/// is the one state the user cannot see and therefore cannot end.
class DiagnosticsShareScreen extends StatefulWidget {
  const DiagnosticsShareScreen({
    super.key,
    required this.snapshot,
    this.server,
  });

  /// The exact text to serve — the same snapshot the send screen showed.
  final String snapshot;

  /// Injected by tests; otherwise this screen owns one.
  final DiagnosticsShareServer? server;

  @override
  State<DiagnosticsShareScreen> createState() => _DiagnosticsShareScreenState();
}

class _DiagnosticsShareScreenState extends State<DiagnosticsShareScreen>
    with WidgetsBindingObserver {
  late final DiagnosticsShareServer _server =
      widget.server ?? DiagnosticsShareServer();

  DiagnosticsShareHandle? _handle;
  String _error = '';
  bool _starting = true;
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_start());
  }

  @override
  void dispose() {
    _tick?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    // Stopped unconditionally, including a server the caller injected: leaving
    // a bound socket serving a log after the screen that advertises it has gone
    // is exactly the state this whole screen is careful about, and ownership is
    // not a good enough reason to leave one open. Not awaited, because
    // `dispose` cannot be async — `stop()` is idempotent and safe in flight.
    unawaited(_server.stop());
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) return;
    // Paused, inactive, hidden or detached: the user can no longer see that a
    // share is open, so it stops. Restarting is one visible button away.
    if (!_server.isRunning) return;
    unawaited(_stop());
  }

  Future<void> _start() async {
    setState(() {
      _starting = true;
      _error = '';
    });
    try {
      final handle = await _server.start(widget.snapshot);
      if (!mounted) {
        unawaited(_server.stop());
        return;
      }
      setState(() {
        _handle = handle;
        _starting = false;
      });
      _tick?.cancel();
      // Redraws the remaining-time line. One second is the coarsest tick that
      // still makes a countdown look like one.
      _tick = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted) return;
        if (!_server.isRunning) {
          setState(() => _handle = null);
          return;
        }
        setState(() {});
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _starting = false;
        _handle = null;
        // A bind failure is a local, non-credential error (permission denied,
        // no network). Its text is safe, but it is phrased for a human rather
        // than echoed raw.
        _error =
            'Could not start the share. Check that the device is connected to '
            'a network and try again.';
      });
    }
  }

  Future<void> _stop() async {
    _tick?.cancel();
    _tick = null;
    await _server.stop();
    if (!mounted) return;
    setState(() => _handle = null);
  }

  void _copy(String value) {
    Clipboard.setData(ClipboardData(text: value));
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Link copied')));
  }

  Duration get _remaining {
    final handle = _handle;
    if (handle == null) return Duration.zero;
    final left = handle.expiresAt.difference(DateTime.now());
    return left.isNegative ? Duration.zero : left;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Share on Wi-Fi')),
      body: SafeArea(
        top: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              maxWidth: kSettingsMaxContentWidth,
            ),
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: _body(),
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _body() {
    if (_starting) {
      return const [
        Padding(
          padding: EdgeInsets.symmetric(vertical: 24),
          child: Center(child: CircularProgressIndicator()),
        ),
      ];
    }
    if (_error.isNotEmpty) return _errorBody();
    final handle = _handle;
    if (handle == null) return _stoppedBody();
    if (handle.addresses.isEmpty) return _noAddressBody();
    return _runningBody(handle);
  }

  List<Widget> _runningBody(DiagnosticsShareHandle handle) {
    final minutes = _remaining.inMinutes;
    final seconds = _remaining.inSeconds % 60;
    return [
      const Text(
        'Open one of these on your phone — your phone must be on the same '
        'Wi-Fi as this device.',
        style: TextStyle(color: AppColors.textHi, height: 1.4),
      ),
      const SizedBox(height: 16),
      for (final address in handle.addresses) ...[
        _AddressCard(
          address: address,
          // The first card holds focus on entry, so a D-pad lands on something
          // visible rather than on an unfocused scaffold.
          autofocus: address == handle.addresses.first,
          onCopy: () => _copy(address.url),
        ),
        const SizedBox(height: 12),
      ],
      const SizedBox(height: 4),
      Text(
        'Sharing stops automatically in '
        '${minutes.toString()}:${seconds.toString().padLeft(2, '0')}.',
        style: const TextStyle(color: AppColors.textLo, fontSize: 12),
      ),
      const SizedBox(height: 12),
      // Said plainly, because it is true and because the mitigation — close it
      // when you are done — is something only the user can do.
      const Text(
        'This link is plain HTTP on your local network. While it is open, '
        'anyone else on the same network who knows the address could read the '
        'log. Stop sharing when you are done.',
        style: TextStyle(color: AppColors.warning, fontSize: 12, height: 1.35),
      ),
      const SizedBox(height: 20),
      Wrap(
        spacing: 12,
        runSpacing: 12,
        children: [
          OutlinedButton.icon(
            onPressed: _stop,
            icon: const Icon(Icons.stop_circle_outlined, size: 18),
            label: const Text('Stop sharing'),
          ),
          OutlinedButton(
            onPressed: () => Navigator.of(context).maybePop(),
            child: const Text('Done'),
          ),
        ],
      ),
    ];
  }

  List<Widget> _stoppedBody() => [
    const Text(
      'Sharing has stopped. The link no longer works.',
      style: TextStyle(color: AppColors.textHi, height: 1.4),
    ),
    const SizedBox(height: 20),
    Wrap(
      spacing: 12,
      runSpacing: 12,
      children: [
        FilledButton.icon(
          autofocus: true,
          onPressed: _start,
          icon: const Icon(Icons.refresh, size: 18),
          // A restart mints a **new** path token and a new port, so an address
          // someone wrote down during the last window is dead. That is the
          // point, and it is why this is "Restart" rather than "Resume".
          label: const Text('Restart'),
        ),
        OutlinedButton(
          onPressed: () => Navigator.of(context).maybePop(),
          child: const Text('Done'),
        ),
      ],
    ),
  ];

  List<Widget> _noAddressBody() => [
    const Text(
      'This device has no usable network address, so there is nothing a phone '
      'could open. Connect it to Wi-Fi or Ethernet and try again.',
      style: TextStyle(color: AppColors.textHi, height: 1.4),
    ),
    const SizedBox(height: 20),
    Wrap(
      spacing: 12,
      runSpacing: 12,
      children: [
        FilledButton.icon(
          autofocus: true,
          onPressed: _start,
          icon: const Icon(Icons.refresh, size: 18),
          label: const Text('Try again'),
        ),
        OutlinedButton(
          onPressed: () => Navigator.of(context).maybePop(),
          child: const Text('Done'),
        ),
      ],
    ),
  ];

  List<Widget> _errorBody() => [
    Text(
      _error,
      style: const TextStyle(color: AppColors.danger, height: 1.4),
    ),
    const SizedBox(height: 20),
    Wrap(
      spacing: 12,
      runSpacing: 12,
      children: [
        FilledButton.icon(
          autofocus: true,
          onPressed: _start,
          icon: const Icon(Icons.refresh, size: 18),
          label: const Text('Try again'),
        ),
        OutlinedButton(
          onPressed: () => Navigator.of(context).maybePop(),
          child: const Text('Done'),
        ),
      ],
    ),
  ];
}

/// One advertised address: its name, the URL in full, a QR of it, and Copy.
///
/// The QR is what makes this usable from a sofa — nobody types
/// `http://192.168.1.42:51873/9f2c…` off a television correctly — but the
/// printed URL stays beside it, because a scan fails exactly where a QR is
/// most wanted (a lit panel across a room, through glare).
class _AddressCard extends StatelessWidget {
  const _AddressCard({
    required this.address,
    required this.onCopy,
    this.autofocus = false,
  });

  final DiagnosticsShareAddress address;
  final VoidCallback onCopy;
  final bool autofocus;

  static const double _qrSide = 150;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppColors.panel,
        borderRadius: BorderRadius.circular(AppRadius.tile),
        border: Border.all(color: AppColors.line),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              address.label,
              style: const TextStyle(
                color: AppColors.textHi,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            // Plain `Text`: `SelectableText` builds a read-only `EditableText`,
            // which is a focus target that eats arrow keys to move a caret —
            // the D-pad trap CLAUDE.md bans from a TV-facing screen. "Copy
            // link" below is the affordance, on every input device.
            Text(
              address.url,
              style: const TextStyle(
                color: AppColors.textLo,
                fontSize: 12,
                fontFamily: 'monospace',
              ),
            ),
            const SizedBox(height: 12),
            Center(child: _UrlQr(url: address.url)),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              autofocus: autofocus,
              onPressed: onCopy,
              icon: const Icon(Icons.copy_outlined, size: 18),
              label: const Text('Copy link'),
            ),
          ],
        ),
      ),
    );
  }
}

/// A QR of one share URL.
///
/// Same two rules `PairingQrView` documents: an explicitly white plate with
/// black modules (the default transparent background is unscannable on this
/// dark card), and a length bound ahead of the encode, because
/// `QrValidator.validate` reports *valid* for a payload that then throws
/// inside the painter. A share URL is ~45 characters, so the bound only ever
/// fires on something that has gone wrong upstream.
class _UrlQr extends StatelessWidget {
  const _UrlQr({required this.url});

  final String url;

  static const int _maxLength = 200;
  static const double _side = _AddressCard._qrSide;

  @override
  Widget build(BuildContext context) {
    if (url.isEmpty || url.length > _maxLength) return const SizedBox.shrink();
    final validation = QrValidator.validate(
      data: url,
      errorCorrectionLevel: QrErrorCorrectLevel.M,
    );
    if (!validation.isValid) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
      ),
      child: SizedBox.square(
        dimension: _side,
        child: QrImageView(
          data: url,
          size: _side,
          padding: EdgeInsets.zero,
          errorCorrectionLevel: QrErrorCorrectLevel.M,
          backgroundColor: Colors.white,
          eyeStyle: const QrEyeStyle(
            eyeShape: QrEyeShape.square,
            color: Colors.black,
          ),
          dataModuleStyle: const QrDataModuleStyle(
            dataModuleShape: QrDataModuleShape.square,
            color: Colors.black,
          ),
          semanticsLabel:
              'QR code that opens the diagnostics log on another device',
        ),
      ),
    );
  }
}
