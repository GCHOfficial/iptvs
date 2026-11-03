/// Uploading the diagnostics log to the app developer, by code.
///
/// ## The one thing to understand before touching this
///
/// **This calls Supabase with the publishable key and no session, and it must
/// stay that way.** `supabase_flutter` sends `apikey: <publishable key>` and
/// `Authorization: Bearer <access token ?? publishable key>` on every request;
/// with no session there is no access token, so PostgREST resolves the request
/// to the **`anon`** role and `submit_diagnostics` — the one write RPC in this
/// schema granted to `anon` — runs. Nothing here calls
/// `CloudSync.ensureAnonSession()`, and nothing here may ever start calling it.
///
/// An anonymous sign-in would mint a permanent `auth.users` row that counts
/// toward the project's monthly active users forever. This repo has already
/// paid that bill once: the profile picker used to create a session on the boot
/// path and produced ~1,900 anonymous users against 62 devices that ever paired
/// (docs/cloud-sync.md). A support button pressed by people who are, by
/// definition, having a bad time would do the same thing again — and buy
/// nothing, because a per-session meter is not a bound when sessions are free
/// to mint. That is exactly why every limit on the server side is global rather
/// than per-subject.
///
/// A device that *is* paired already has a session and will call as
/// `authenticated` instead. That is fine and deliberate — the RPC is granted to
/// both roles, and the metering does not care which one arrives.
library;

import 'dart:io' show Platform;

import 'package:supabase_flutter/supabase_flutter.dart';

import 'cloud_config.dart';
import 'device_class.dart';
import 'device_label.dart';
import 'diagnostics_log.dart';
import 'distribution_channel.dart';
import 'update_service.dart';

/// How the send screen asks for an upload. Injectable so the screen can be
/// widget-tested without a Supabase client (there is no fake for one, and the
/// screen's real subject is its focus order and its consent text).
typedef DiagnosticsSubmit = Future<String> Function(String body);

/// Submits [body] and returns the `D-XXXXXX` code the user reads out.
///
/// [client] exists for tests and for a caller that has its own client; the
/// default is the process-wide one `main.dart` initialised. Throws
/// [StateError] when the build carries no Supabase config at all — the send
/// screen hides the cloud option in that case, so reaching here would be a
/// wiring bug rather than a user-visible state.
///
/// Errors are left to propagate: `friendlyCloudError` is the only thing allowed
/// to turn a `PostgrestException` into something a user reads, and it lives
/// with the rest of the cloud error vocabulary.
Future<String> submitDiagnostics(String body, {SupabaseClient? client}) async {
  if (!CloudConfig.isConfigured) {
    throw StateError('diagnostics upload requires Supabase configuration');
  }
  final supabase = client ?? Supabase.instance.client;
  final metadata = await describeInstallForDiagnostics();
  final result = await supabase.rpc(
    'submit_diagnostics',
    params: {
      'p_body': body,
      // Every parameter is sent on every call, with no reliance on a server
      // DEFAULT. PostgREST resolves an overload by the set of parameter *names*
      // in the body, so a partial payload is how a future second arity turns
      // into a `PGRST203` that breaks every install at once — the failure mode
      // the pairing RPCs are still carrying a permanent delegate to avoid.
      'p_app_version': metadata.appVersion,
      'p_platform': metadata.platform,
      'p_channel': metadata.channel,
      'p_is_tv': metadata.isTv,
      'p_install_hint': metadata.installHint,
    },
  );
  final code = result is String ? result : '';
  if (code.isEmpty) {
    throw StateError('diagnostics upload returned no code');
  }
  return code;
}

/// The handful of self-asserted facts sent beside the log.
///
/// Every field here is **chosen by the client and trusted by nobody** — the
/// server bounds their length and rejects control characters, and the panel
/// escapes them, precisely because an unauthenticated caller picks them. They
/// exist so a developer reading an inbox can tell an Android TV report from a
/// Windows one without opening every body.
class DiagnosticsInstallInfo {
  final String appVersion;
  final String platform;
  final String channel;
  final bool isTv;

  /// A **device-class** hint ("Android TV", "Windows PC"), not an install
  /// identity.
  ///
  /// The obvious reading of the column name would be a persistent per-install
  /// identifier, and that is deliberately not what this is: minting and storing
  /// one would create a new, permanent, cross-report correlation handle for a
  /// feature whose entire pitch to the user is "this is one log, kept 30 days".
  /// The same string the pairing screen already suggests as a device name costs
  /// nothing, is already understood to be a display string with no authority,
  /// and answers the question a developer actually has.
  final String installHint;

  const DiagnosticsInstallInfo({
    required this.appVersion,
    required this.platform,
    required this.channel,
    required this.isTv,
    required this.installHint,
  });
}

/// Collects [DiagnosticsInstallInfo] for this build.
///
/// Never throws and never blocks the send on a platform round trip that is only
/// cosmetic: anything that fails degrades to an empty string, and an empty
/// metadata field is exactly as acceptable to the server as a populated one.
Future<DiagnosticsInstallInfo> describeInstallForDiagnostics() async {
  String version;
  try {
    version = await appVersion();
  } catch (_) {
    version = '';
  }
  String hint;
  try {
    hint = await detectSuggestedDeviceLabel();
  } catch (_) {
    hint = '';
  }
  return DiagnosticsInstallInfo(
    appVersion: _bounded(version),
    platform: _bounded(_operatingSystem()),
    channel: _bounded(DistributionConfig.rawChannel),
    isTv: isTelevision,
    installHint: _bounded(hint),
  );
}

String _operatingSystem() {
  try {
    return Platform.operatingSystem;
  } catch (_) {
    return '';
  }
}

/// Mirrors the server's own bound (64 characters, no control characters) so a
/// surprising platform string becomes a shortened field rather than a rejected
/// submission. The server still enforces it; this just keeps the failure from
/// being the user's problem.
String _bounded(String value) {
  final cleaned = value.replaceAll(RegExp(r'[\u0000-\u001F\u007F-\u009F]'), '');
  return cleaned.length <= 64 ? cleaned : cleaned.substring(0, 64);
}

/// The snapshot both send paths serve: the log as text, trimmed to the server's
/// ceiling. Taken once, when the user presses Send.
String diagnosticsSnapshot() =>
    DiagnosticsLog.instance.asTextBounded(kDiagnosticsMaxUploadBytes);
