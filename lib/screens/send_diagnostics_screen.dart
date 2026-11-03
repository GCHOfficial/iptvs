import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../data/cloud_config.dart';
import '../data/cloud_sync.dart' show friendlyCloudError;
import '../data/diagnostics_share_server.dart';
import '../data/diagnostics_upload.dart';
import '../theme.dart';
import 'diagnostics_share_screen.dart';

/// The consent the user reads before anything leaves the device.
///
/// **Verbatim, and deliberately specific.** A generic "send anonymous
/// diagnostics?" would be a lie: this log names the user's provider, their
/// sources and profiles, the channels they opened and when. Listing those is
/// the difference between consent and a dialog people tap through. The
/// reassurance about credentials is placed *after* the list of what is
/// included, so it reads as a qualification rather than as the headline.
///
/// Changing this string changes what the user agreed to. Change the behaviour
/// first.
const String kDiagnosticsConsentText =
    'This sends your diagnostics log to the app developer. It contains your '
    "IPTV provider's address, your source and profile names, channel names, "
    'and times you watched. Passwords and credentials are removed '
    'automatically. It is stored for 30 days and only the developer can read '
    'it. Do not send it if anything on the Diagnostics screen looks private.';

enum _SendPhase { consent, sending, sent, failed }

/// "Send diagnostics" — a pushed route off the Diagnostics screen.
///
/// ## Navigation
///
/// An ordinary `MaterialPageRoute`: Back is a plain pop, and this screen adds
/// **no rung to the channel list's Back ladder**. That ladder is about peeling
/// state off one screen; this is a different screen, and the ladder's rule —
/// "Back never changes data or filters" — is satisfied trivially by a route
/// that owns no data.
///
/// ## Focus
///
/// **Cancel autofocuses, and Send is one D-pad step away.** This is the one
/// screen in the app where the destructive-by-default reading is the right one:
/// the action is irreversible (there is no unsend, and no developer delete
/// path), its subject is the user's own viewing history, and the screen is
/// reached by someone pressing buttons on a remote. Autofocusing the primary
/// action — which every other dialog in this app does, including the update
/// prompt — would make a single stray OK press publish a log. A remote user
/// pays one extra keypress; that is the correct price.
///
/// There is deliberately **no text field anywhere on this screen**, so nothing
/// can trap D-pad focus and no IME is ever summoned (CLAUDE.md's TV rule). The
/// code that comes back is copied, scanned, or read out — never typed here.
class SendDiagnosticsScreen extends StatefulWidget {
  const SendDiagnosticsScreen({
    super.key,
    this.submit,
    this.shareServer,
    this.snapshot,
    this.cloudAvailable,
  });

  /// How to upload. Defaults to [submitDiagnostics]; injected by tests, which
  /// have no Supabase client to talk to.
  final DiagnosticsSubmit? submit;

  /// The LAN fallback's server. Injected so a test can assert the screen's
  /// wiring without binding a socket.
  final DiagnosticsShareServer? shareServer;

  /// The exact text that will be sent. Captured **once**, when this route is
  /// built, so the log the user reads here is byte-for-byte the log that
  /// leaves — a player still running behind this screen keeps appending to
  /// [DiagnosticsLog], and a snapshot re-read at Send time would not be the
  /// one that was consented to.
  final String? snapshot;

  /// Whether the cloud path exists in this build. Defaults to
  /// [CloudConfig.isConfigured]; a build with no Supabase config shows the LAN
  /// option as the only — and therefore primary — way out.
  final bool? cloudAvailable;

  @override
  State<SendDiagnosticsScreen> createState() => _SendDiagnosticsScreenState();
}

class _SendDiagnosticsScreenState extends State<SendDiagnosticsScreen> {
  late final String _snapshot = widget.snapshot ?? diagnosticsSnapshot();
  late final bool _cloud = widget.cloudAvailable ?? CloudConfig.isConfigured;
  late final DiagnosticsSubmit _submit = widget.submit ?? submitDiagnostics;

  _SendPhase _phase = _SendPhase.consent;
  String _code = '';
  String _error = '';

  Future<void> _send() async {
    setState(() => _phase = _SendPhase.sending);
    try {
      final code = await _submit(_snapshot);
      if (!mounted) return;
      setState(() {
        _code = code;
        _phase = _SendPhase.sent;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        // `friendlyCloudError` is the only thing allowed to turn a server
        // failure into user-visible text: it renders the server's own
        // `iptvs: ` messages verbatim and genericises everything else, and it
        // never reads Postgres `details`/`hint`, which for a constraint
        // violation would carry the offending row.
        _error = friendlyCloudError(e);
        _phase = _SendPhase.failed;
      });
    }
  }

  Future<void> _shareOverLan() async {
    final server = widget.shareServer;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => DiagnosticsShareScreen(
          snapshot: _snapshot,
          server: server,
        ),
      ),
    );
  }

  void _copy(String value, String toast) {
    Clipboard.setData(ClipboardData(text: value));
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(toast)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Send diagnostics')),
      // Edge-to-edge (targetSdk 35+): in landscape the system bar sits on the
      // side, where the action row's trailing button would otherwise go.
      body: SafeArea(
        top: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              maxWidth: kSettingsMaxContentWidth,
            ),
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: switch (_phase) {
                _SendPhase.consent || _SendPhase.sending => _consentBody(),
                _SendPhase.sent => _sentBody(),
                _SendPhase.failed => _failedBody(),
              },
            ),
          ),
        ),
      ),
    );
  }

  // ── consent ───────────────────────────────────────────────────────────────

  List<Widget> _consentBody() {
    final sending = _phase == _SendPhase.sending;
    return [
      const Text(
        kDiagnosticsConsentText,
        style: TextStyle(color: AppColors.textHi, height: 1.4),
      ),
      const SizedBox(height: 16),
      _LogPreview(text: _snapshot),
      const SizedBox(height: 16),
      if (sending)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 12),
          child: Row(
            children: [
              SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              SizedBox(width: 12),
              Text('Sending…', style: TextStyle(color: AppColors.textLo)),
            ],
          ),
        )
      else
        _ActionRow(
          children: [
            // First in the row AND the autofocus target — see the class doc.
            OutlinedButton(
              autofocus: true,
              onPressed: () => Navigator.of(context).maybePop(),
              child: const Text('Cancel'),
            ),
            if (_cloud)
              FilledButton.icon(
                onPressed: _send,
                icon: const Icon(Icons.cloud_upload_outlined, size: 18),
                label: const Text('Send to developer'),
              ),
            // Primary styling when it is the only way out of this screen.
            if (_cloud)
              OutlinedButton.icon(
                onPressed: _shareOverLan,
                icon: const Icon(Icons.wifi_tethering, size: 18),
                label: const Text('Share on Wi-Fi'),
              )
            else
              FilledButton.icon(
                onPressed: _shareOverLan,
                icon: const Icon(Icons.wifi_tethering, size: 18),
                label: const Text('Share on Wi-Fi'),
              ),
          ],
        ),
      if (!_cloud) ...[
        const SizedBox(height: 12),
        const Text(
          'This build has no cloud support, so the log can only be handed over '
          'on your local network.',
          style: TextStyle(color: AppColors.textLo, fontSize: 12),
        ),
      ],
    ];
  }

  // ── sent ──────────────────────────────────────────────────────────────────

  List<Widget> _sentBody() => [
    const Text(
      'Sent. Give the developer this code — it is how they find your log.',
      style: TextStyle(color: AppColors.textHi, height: 1.4),
    ),
    const SizedBox(height: 20),
    Center(
      // Plain `Text`, deliberately. `SelectableText` builds a read-only
      // `EditableText`, which is a focus target that swallows arrow keys to
      // move a caret — i.e. precisely the D-pad trap CLAUDE.md bans from a
      // TV-facing screen, dressed up as a convenience. Copy is the affordance
      // instead, and it works on every input device.
      child: Text(
        _code,
        style: const TextStyle(
          color: AppColors.textHi,
          // Large, monospaced and widely tracked: this is read off a
          // television across a room, or spoken down a phone line. The
          // alphabet it is drawn from already excludes I/L/O/0/1; the type has
          // to do the rest.
          fontSize: 40,
          fontWeight: FontWeight.w700,
          fontFamily: 'monospace',
          letterSpacing: 4,
        ),
      ),
    ),
    const SizedBox(height: 16),
    // The **bare code**, not a URL. There is no page to land on: the code is
    // an identifier the developer looks up in their own panel, and encoding a
    // link would invite someone to follow it and find nothing.
    Center(child: _CodeQr(code: _code)),
    const SizedBox(height: 20),
    _ActionRow(
      children: [
        FilledButton.icon(
          autofocus: true,
          onPressed: () => _copy(_code, 'Code copied'),
          icon: const Icon(Icons.copy_outlined, size: 18),
          label: const Text('Copy'),
        ),
        OutlinedButton(
          onPressed: () => Navigator.of(context).maybePop(),
          child: const Text('Done'),
        ),
      ],
    ),
    const SizedBox(height: 16),
    const Text(
      'The log is stored for 30 days and then deleted automatically.',
      style: TextStyle(color: AppColors.textLo, fontSize: 12),
    ),
  ];

  // ── failed ────────────────────────────────────────────────────────────────

  List<Widget> _failedBody() => [
    Text(
      _error.isEmpty ? 'Sending failed.' : _error,
      style: const TextStyle(color: AppColors.danger, height: 1.4),
    ),
    const SizedBox(height: 16),
    const Text(
      'You can try again, or hand the log over on your local network instead.',
      style: TextStyle(color: AppColors.textLo),
    ),
    const SizedBox(height: 20),
    _ActionRow(
      children: [
        // Retry autofocuses here — the same rule `SourceErrorView` follows.
        // Unlike the consent screen, the user has already consented *and*
        // pressed Send; the dangerous press is behind them, and what is left
        // is the one action that moves them forward.
        FilledButton.icon(
          autofocus: true,
          onPressed: _send,
          icon: const Icon(Icons.refresh, size: 18),
          label: const Text('Try again'),
        ),
        OutlinedButton.icon(
          onPressed: _shareOverLan,
          icon: const Icon(Icons.wifi_tethering, size: 18),
          label: const Text('Share on Wi-Fi'),
        ),
        OutlinedButton(
          onPressed: () => Navigator.of(context).maybePop(),
          child: const Text('Cancel'),
        ),
      ],
    ),
  ];
}

/// The action row, wrapped rather than laid out in a `Row`.
///
/// Three buttons with words on them do not fit a 320 px phone at text scale
/// 2.0, and an overflowing `Row` on a TV-facing screen means a focus target
/// drawn off the edge — reachable by the D-pad, invisible to the user.
class _ActionRow extends StatelessWidget {
  const _ActionRow({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) =>
      Wrap(spacing: 12, runSpacing: 12, children: children);
}

/// The log, exactly as it will be sent.
///
/// Bounded in height and scrollable: "do not send it if anything looks private"
/// is only actionable if the thing can be read, and a 256 KiB log cannot be a
/// column on the page.
///
/// Plain `Text`, not `SelectableText` — see the note on the code display. The
/// scroll view itself is not a focus target either, so a D-pad walks straight
/// past this onto the action row; a mouse and a touchscreen still scroll it.
class _LogPreview extends StatelessWidget {
  const _LogPreview({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: AppColors.panel,
      borderRadius: BorderRadius.circular(AppRadius.tile),
      border: Border.all(color: AppColors.line),
    ),
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 220),
      child: Scrollbar(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(12),
          child: Text(
            text,
            style: const TextStyle(
              color: AppColors.textLo,
              fontSize: 11,
              height: 1.35,
              fontFamily: 'monospace',
            ),
          ),
        ),
      ),
    ),
  );
}

/// A QR of a short bare string, on a white plate.
///
/// A sibling of `PairingQrView` rather than a reuse of it: that widget encodes
/// a *link* and says so in its caption and its semantics label, and pointing a
/// camera at this one lands you on a code with nowhere to go. The two safety
/// rules it documents are reproduced because they are real:
///
///   * the plate is explicitly white with black modules — `QrImageView`'s
///     background defaults to transparent, which on this dark card is visibly
///     present and scannable as nothing;
///   * the payload is validated first. (`QrValidator.validate` is optimistic
///     for long payloads, but 8 characters is nowhere near any version's
///     capacity, so here the validation is only catching a malformed one.)
class _CodeQr extends StatelessWidget {
  const _CodeQr({required this.code});

  final String code;

  static const double _side = 160;

  @override
  Widget build(BuildContext context) {
    if (code.isEmpty) return const SizedBox.shrink();
    final validation = QrValidator.validate(
      data: code,
      errorCorrectionLevel: QrErrorCorrectLevel.M,
    );
    if (!validation.isValid) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
      ),
      child: SizedBox.square(
        dimension: _side,
        child: QrImageView(
          data: code,
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
          semanticsLabel: 'QR code containing the diagnostics code $code',
        ),
      ),
    );
  }
}
