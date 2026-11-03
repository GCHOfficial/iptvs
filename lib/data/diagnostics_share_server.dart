import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import '../player/resource_counters.dart';
import 'diagnostics_log.dart';

/// One advertised way to reach a running share.
///
/// A device can sit on several networks at once (a TV box cabled *and*
/// associated to Wi-Fi, a desktop with a hypervisor's virtual switch), and only
/// the human in the room knows which one their phone is on. So the share
/// advertises every candidate rather than guessing, and [label] exists purely
/// so "192.168.1.42" and "172.17.0.1" are told apart by something other than
/// the digits.
class DiagnosticsShareAddress {
  /// "Wi-Fi", "Ethernet", or the raw interface name when neither fits.
  final String label;

  /// The bare IPv4 host, e.g. `192.168.1.42` — shown beside the URL because a
  /// user typing it by hand on a phone keyboard needs the short form.
  final String host;

  /// The full URL to open, e.g. `http://192.168.1.42:54321/<token>`.
  final String url;

  const DiagnosticsShareAddress({
    required this.label,
    required this.host,
    required this.url,
  });
}

/// A running share: the ephemeral port it bound, the one-off path token that
/// authorizes the body, where to reach it, and when it dies.
class DiagnosticsShareHandle {
  final int port;

  /// 32 lowercase hex characters (16 bytes from [Random.secure]). This is the
  /// *only* thing protecting the log body on a LAN that may have guests on it,
  /// so it is never logged and never printed anywhere except the URL the user
  /// is looking at.
  final String token;

  /// May be empty — a device with no usable NIC (every address loopback or
  /// link-local, or the enumeration failed) still binds successfully and still
  /// has a port, it just has nothing to advertise. The UI needs to say so
  /// rather than render an empty list as success.
  final List<DiagnosticsShareAddress> addresses;

  final DateTime expiresAt;

  const DiagnosticsShareHandle({
    required this.port,
    required this.token,
    required this.addresses,
    required this.expiresAt,
  });
}

/// A throwaway HTTP server that hands one fixed string — a snapshot of the
/// diagnostics log, taken when the user pressed Send — to a phone on the same
/// Wi-Fi, and then dies.
///
/// This is the **LAN fallback** for getting a log off a television: the set-top
/// box has no mail client, no file manager worth the name, and a remote control
/// instead of a keyboard, so the cloud path is the normal route and this is what
/// is left when it isn't available. The whole design is therefore shaped by
/// "this is a credential-bearing document briefly readable by anything on the
/// local network":
///
/// * the body is a **snapshot**, captured by the caller before [start], so the
///   bytes served never change under a reader and nothing logged *after* the
///   user consented to share is in it;
/// * the port is **ephemeral** and the path is a **secret token**, so neither is
///   predictable across runs and a port scan finds a server that answers 404 to
///   everything it can guess;
/// * a `Host:` header that isn't an IP literal is refused outright, which is
///   what stops a browser from being walked onto the share by DNS rebinding;
/// * there is a **hard ceiling on lifetime** ([maxLifetime]) rather than a
///   "stop sharing" button alone — the failure mode to design against is the
///   user wandering off and leaving the log readable, not the user being unable
///   to stop it.
///
/// Deliberately *not* here: any CORS header (a page in a browser on the LAN has
/// no business reading this cross-origin — the user opens the URL directly), and
/// any form of discovery/advertisement (mDNS and friends would publish the
/// share's existence to the whole network for its whole life).
class DiagnosticsShareServer {
  /// The hard ceiling the design fixes: a share is never open longer than this,
  /// whatever a caller asks for. Long enough to unlock a phone, find the Wi-Fi
  /// it is actually on and type an address; short enough that a forgotten share
  /// is gone before anyone wanders past.
  static const Duration maxLifetime = Duration(minutes: 5);

  HttpServer? _server;
  Timer? _expiry;
  DiagnosticsShareHandle? _handle;

  /// Whether [ResourceCounters.incDiagnosticsShareServers] has fired for the
  /// *current* server and not yet been matched. The counter is the leak alarm,
  /// so it must survive both halves of the obvious abuse: a bind that threw
  /// (never incremented, so [stop] must not decrement) and a double [stop]
  /// (decrementing twice would drive it negative and make the alarm read as a
  /// surplus somewhere else).
  bool _counted = false;

  bool get isRunning => _server != null;

  DiagnosticsShareHandle? get handle => _handle;

  /// Binds, starts serving [body], and auto-stops after [lifetime] (clamped to
  /// [maxLifetime], and to something positive).
  ///
  /// Throws whatever the bind threw — a refused port, a missing network
  /// permission — so the UI can say why instead of showing a URL that answers
  /// nothing. On that path nothing is counted and [isRunning] stays false.
  Future<DiagnosticsShareHandle> start(
    String body, {
    Duration lifetime = maxLifetime,
  }) async {
    // Starting twice would otherwise strand the first server (and its counter)
    // with nothing holding a reference to it.
    await stop();

    final effectiveLifetime = _clampLifetime(lifetime);
    final token = _newToken();
    final bytes = Uint8List.fromList(utf8.encode(body));

    // Ephemeral port (0) on every IPv4 interface: predictability is the thing
    // being avoided, and `shared: false` so a second share can never silently
    // round-robin requests with this one.
    final server = await HttpServer.bind(
      InternetAddress.anyIPv4,
      0,
      shared: false,
    );
    ResourceCounters.incDiagnosticsShareServers();
    _counted = true;
    _server = server;

    final addresses = await _advertisedAddresses(server.port, token);
    final handle = DiagnosticsShareHandle(
      port: server.port,
      token: token,
      addresses: addresses,
      expiresAt: DateTime.now().add(effectiveLifetime),
    );
    _handle = handle;

    _expiry = Timer(effectiveLifetime, () {
      unawaited(stop());
    });

    server.listen(
      (request) => _serve(request, token, bytes),
      // A connection that dies mid-request is ordinary on a LAN (a phone
      // locking its screen does it); it must not take the server down.
      onError: (Object _) {},
      cancelOnError: false,
    );

    // Port and address *count* only: the token is the whole of the access
    // control and the body is the log itself, so neither may ever reach the
    // log — which is a document the user is about to hand to someone else.
    DiagnosticsLog.instance.add(
      'share',
      'start port=${server.port} addresses=${addresses.length} '
      'lifetime_ms=${effectiveLifetime.inMilliseconds}',
    );
    return handle;
  }

  /// Idempotent: safe to call when never started, and safe to call twice (the
  /// expiry timer and a user pressing Stop race by construction).
  Future<void> stop() async {
    _expiry?.cancel();
    _expiry = null;

    // Claim the server synchronously, before the first await, so two
    // overlapping stops can't both close it or both decrement.
    final server = _server;
    _server = null;
    _handle = null;
    if (_counted) {
      ResourceCounters.decDiagnosticsShareServers();
      _counted = false;
    }
    if (server == null) return;

    DiagnosticsLog.instance.add('share', 'stop port=${server.port}');
    // force: true — a reader that opened a connection and stalled must not be
    // able to hold the share open past its window.
    await server.close(force: true);
  }

  Future<void> _serve(
    HttpRequest request,
    String token,
    Uint8List bytes,
  ) async {
    final response = request.response;
    try {
      // The rebinding check runs *first*, ahead of the path check, so that a
      // caller arriving under an attacker-chosen hostname gets one answer for
      // every request. Checking the path first would make the 404/403 split a
      // path oracle — exactly the thing the token exists to deny.
      if (!isIpLiteralHost(request.headers.value(HttpHeaders.hostHeader))) {
        await _refuse(response, HttpStatus.forbidden);
        return;
      }

      final method = request.method;
      final isHead = method == 'HEAD';
      // Anything that isn't a read of the one route — another path, POST,
      // OPTIONS (there is no CORS preflight to answer here, by design) — gets
      // the same bodiless 404, which describes nothing about the real path.
      if (!isHead && method != 'GET') {
        await _refuse(response, HttpStatus.notFound);
        return;
      }
      if (!_constantTimeEquals(request.uri.path, '/$token')) {
        await _refuse(response, HttpStatus.notFound);
        return;
      }

      // Deliberately *not* single-use. A link pasted into a chat app is fetched
      // by that app's link-preview crawler before the human ever taps it, so a
      // one-shot URL would reliably be spent by a robot and leave the user with
      // a dead link and no idea why. The window, not the read count, is the
      // bound.
      response.statusCode = HttpStatus.ok;
      response.headers.contentType = ContentType(
        'text',
        'plain',
        charset: 'utf-8',
      );
      response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
      response.headers.set('X-Content-Type-Options', 'nosniff');
      // The URL carries the token in its path, so any outbound navigation from
      // a rendered view of this document must not carry it in a Referer.
      response.headers.set('Referrer-Policy', 'no-referrer');
      response.headers.removeAll(HttpHeaders.serverHeader);
      response.contentLength = bytes.length;
      if (!isHead) response.add(bytes);
      await response.close();
    } catch (_) {
      // A dropped connection surfaces here as a write error; there is nothing
      // to report and nothing to recover.
    }
  }

  Future<void> _refuse(HttpResponse response, int statusCode) async {
    response.statusCode = statusCode;
    // No body at all: a refusal that explains itself tells a scanner whether it
    // got the path right, the method right, or the Host right.
    response.contentLength = 0;
    response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
    response.headers.removeAll(HttpHeaders.serverHeader);
    await response.close();
  }

  /// Every IPv4 address worth showing, ranked by [rankShareHosts] and labelled
  /// by [shareInterfaceLabel].
  ///
  /// Enumeration failing is not a reason to fail the share: the server is bound
  /// and the port is valid, and a user who knows their device's address can
  /// still be told one. So this degrades to an empty list.
  Future<List<DiagnosticsShareAddress>> _advertisedAddresses(
    int port,
    String token,
  ) async {
    final labels = <String, String>{};
    final ordered = <String>[];
    try {
      final interfaces = await NetworkInterface.list(
        includeLoopback: false,
        includeLinkLocal: false,
        type: InternetAddressType.IPv4,
      );
      for (final interface in interfaces) {
        for (final address in interface.addresses) {
          final host = address.address;
          if (labels.containsKey(host)) continue;
          labels[host] = shareInterfaceLabel(interface.name);
          ordered.add(host);
        }
      }
    } catch (_) {
      return const [];
    }
    return [
      for (final host in rankShareHosts(ordered))
        DiagnosticsShareAddress(
          label: labels[host] ?? host,
          host: host,
          url: 'http://$host:$port/$token',
        ),
    ];
  }

  Duration _clampLifetime(Duration lifetime) {
    if (lifetime > maxLifetime) return maxLifetime;
    // A zero or negative lifetime would arm a timer that fires on the next tick
    // (or never), i.e. a share that exists only as a race.
    if (lifetime <= Duration.zero) return const Duration(milliseconds: 1);
    return lifetime;
  }

  String _newToken() {
    final random = Random.secure();
    final buffer = StringBuffer();
    for (var i = 0; i < 16; i++) {
      buffer.write(random.nextInt(256).toRadixString(16).padLeft(2, '0'));
    }
    return buffer.toString();
  }

  /// Compares a request path against the expected one without leaking where
  /// they first diverge.
  ///
  /// The loop always runs the full length of [expected] — a fixed 33 characters
  /// — and the length mismatch is folded into the same accumulator rather than
  /// returned early, because an early return on length is itself a measurable
  /// answer. Realistically a LAN's jitter swamps this, but the token is the only
  /// thing guarding the body and a constant-time compare costs nothing.
  bool _constantTimeEquals(String candidate, String expected) {
    var difference = candidate.length ^ expected.length;
    for (var i = 0; i < expected.length; i++) {
      final a = i < candidate.length ? candidate.codeUnitAt(i) : 0;
      difference |= a ^ expected.codeUnitAt(i);
    }
    return difference == 0;
  }
}

/// Candidate IPv4 hosts, filtered and ranked for display.
///
/// Drops what can never be reached from the user's phone: loopback (`127/8`,
/// which only the device itself can open) and link-local (`169.254/16`, the
/// address a NIC invents when DHCP failed — present precisely when the network
/// doesn't work). Anything that isn't a well-formed dotted quad is dropped too,
/// since the result is pasted straight into a URL.
///
/// RFC1918 space (`10/8`, `172.16/12`, `192.168/16`) ranks ahead of everything
/// else because the home LAN the phone is on is overwhelmingly one of those,
/// while the remainder is typically a VPN, a container bridge or a carrier-grade
/// NAT address that the phone cannot route to. Nothing is *removed* for being
/// unusual, though — the one address that works is sometimes the odd one, and
/// the user can see the list.
///
/// The incoming order is the tie-break, stated explicitly because `List.sort` is
/// **not stable** and would otherwise reshuffle equally-ranked addresses between
/// runs. Duplicates (the same address on two interfaces) collapse to the first.
List<String> rankShareHosts(Iterable<String> hosts) {
  final seen = <String>{};
  final candidates = <_RankedHost>[];
  for (final host in hosts) {
    final octets = _ipv4Octets(host);
    if (octets == null) continue;
    if (octets[0] == 127) continue; // loopback
    if (octets[0] == 169 && octets[1] == 254) continue; // link-local
    if (!seen.add(host)) continue;
    candidates.add(
      _RankedHost(host, _isPrivateV4(octets) ? 0 : 1, candidates.length),
    );
  }
  candidates.sort((a, b) {
    final byRank = a.rank.compareTo(b.rank);
    return byRank != 0 ? byRank : a.order.compareTo(b.order);
  });
  return [for (final candidate in candidates) candidate.host];
}

class _RankedHost {
  final String host;
  final int rank;
  final int order;

  const _RankedHost(this.host, this.rank, this.order);
}

List<int>? _ipv4Octets(String host) {
  final parts = host.split('.');
  if (parts.length != 4) return null;
  final octets = <int>[];
  for (final part in parts) {
    if (part.isEmpty || part.length > 3) return null;
    final value = int.tryParse(part);
    if (value == null || value < 0 || value > 255) return null;
    octets.add(value);
  }
  return octets;
}

bool _isPrivateV4(List<int> octets) {
  if (octets[0] == 10) return true;
  if (octets[0] == 172 && octets[1] >= 16 && octets[1] <= 31) return true;
  if (octets[0] == 192 && octets[1] == 168) return true;
  return false;
}

/// "Wi-Fi" / "Ethernet" / the raw name, from a platform interface name.
///
/// The label is a hint for a human choosing between two addresses, not an
/// identity — so an unrecognised name is returned **verbatim** rather than
/// guessed at or blanked: `usb0` beside an address is more use than a label
/// invented for it.
///
/// Covers the three naming schemes the app actually meets: Linux/Android legacy
/// (`wlan0`, `eth0`), systemd predictable names (`wlp3s0`, `enp0s3`, `ens33`),
/// and Windows' human-facing names (`Wi-Fi`, `Ethernet 2`). Darwin's `en0` is
/// read as Ethernet even though it is Wi-Fi on most Macs, because the kernel
/// name genuinely doesn't say which and the honest options are "the BSD naming"
/// or "a coin flip" — and the user is picking by address anyway.
String shareInterfaceLabel(String interfaceName) {
  final name = interfaceName.trim();
  if (name.isEmpty) return interfaceName;
  final lower = name.toLowerCase();
  if (lower.startsWith('wlan') ||
      lower.startsWith('wlp') ||
      lower.startsWith('wifi') ||
      lower.startsWith('wi-fi') ||
      lower.startsWith('wireless') ||
      lower.startsWith('wl')) {
    return 'Wi-Fi';
  }
  if (lower.startsWith('eth') ||
      lower.startsWith('en') ||
      lower.startsWith('em') ||
      lower.startsWith('local area connection')) {
    return 'Ethernet';
  }
  return interfaceName;
}

/// True when a `Host:` header value is an IP literal or `localhost` (optionally
/// with a `:port`, and IPv6 in brackets).
///
/// This is the DNS-rebinding gate. A browser pointed at `log.attacker.example`,
/// whose DNS answer is re-pointed at the device's LAN address a moment later,
/// reaches this server with the *attacker's* hostname in `Host:` — same-origin
/// policy then lets the attacker's page read the response. A name can be made to
/// resolve anywhere; an IP literal cannot be made to mean something else, so
/// refusing every non-literal `Host` closes the whole class. The cost is that
/// the share can only ever be opened by address, which is what the UI prints.
///
/// Absent or unparsable is false: fail closed.
bool isIpLiteralHost(String? hostHeader) {
  if (hostHeader == null) return false;
  var value = hostHeader.trim();
  if (value.isEmpty) return false;

  if (value.startsWith('[')) {
    final end = value.indexOf(']');
    if (end < 0) return false;
    final rest = value.substring(end + 1);
    if (!_isEmptyOrPort(rest)) return false;
    final inner = value.substring(1, end);
    final parsed = InternetAddress.tryParse(inner);
    return parsed != null && parsed.type == InternetAddressType.IPv6;
  }

  // A single colon is a port separator; several mean a bracket-less IPv6
  // literal, which is malformed in a Host header but unambiguous enough to
  // judge as written rather than to mis-split into a bogus port.
  final colon = value.indexOf(':');
  if (colon >= 0 && colon == value.lastIndexOf(':')) {
    if (!_isEmptyOrPort(value.substring(colon))) return false;
    value = value.substring(0, colon);
  }
  if (value.isEmpty) return false;
  if (value.toLowerCase() == 'localhost') return true;
  return InternetAddress.tryParse(value) != null;
}

/// `''` or `:<digits>` — anything else trailing a host is not a port.
bool _isEmptyOrPort(String rest) {
  if (rest.isEmpty) return true;
  if (!rest.startsWith(':') || rest.length < 2) return false;
  for (var i = 1; i < rest.length; i++) {
    final code = rest.codeUnitAt(i);
    if (code < 0x30 || code > 0x39) return false;
  }
  return true;
}
