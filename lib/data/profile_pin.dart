import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// Profile PINs — a **4-digit gate**, not a security boundary.
///
/// What the PIN is for: keeping the wrong person (a child, a guest, a flatmate)
/// out of a profile on a shared television. What it is *not* for: protecting
/// the provider credentials inside that profile. Those are protected by the
/// keychain, by RLS, and — when the account opts in — by end-to-end encryption,
/// all of which hold whether or not a PIN is set.
///
/// That distinction is why the verifier below is stored as a salted PBKDF2 hash
/// and *still* treated as public: a 4-digit PIN has ten thousand possible
/// values, so anyone holding the hash can recover the PIN by trying all of them
/// no matter how many iterations we pick. The hash exists so the PIN is not
/// sitting in plain text where a casual read (a keychain dump, a support export,
/// a glance at the panel's network tab) hands it over — it buys obscurity, not
/// strength, and the cloud column that carries it is deliberately a **broad**
/// (non-secret) field for exactly that reason. Iterations are therefore chosen
/// for a cheap set-top box, not for an attacker: see [kProfilePinIterations].
///
/// The encoding is shared with the web panel (`panel/src/pin.js`), which derives
/// the same verifier through WebCrypto, and with Postgres, which only ever
/// checks its *shape* (`profiles_validate`). Keep all three in step — the format
/// string below is the contract.

/// Digits in a profile PIN. Fixed: the on-screen keypad auto-submits on the
/// last digit, and both stores bound the field on this.
const int kProfilePinLength = 4;

/// PBKDF2 iterations. Sized for the slowest device that must *verify* one — a
/// remote-only Android TV box unlocking a profile — because the cost is paid on
/// the UI path and the security benefit is nil (see the note above).
///
/// Cost, stated as what is actually known: one derivation measured ~25 ms in
/// the Dart VM on a desktop. It is pure-Dart HMAC-SHA-256 (~20 000 SHA-256
/// block compressions) run **synchronously on the UI thread**, once per
/// completed entry, so a low-end set-top box could plausibly be several times
/// that — it has not been measured on one. That is the ceiling this number is
/// chosen against: a hundred thousand rounds would multiply an already
/// unmeasured stall by ten and buy nothing, since the keyspace is what makes
/// the verifier recoverable, not the cost per guess.
const int kProfilePinIterations = 10000;

/// Longest verifier this format can produce, and the bound both stores use.
const int kProfilePinVerifierMaxLength = 256;

const String _algorithm = 'pbkdf2-sha256';
const int _saltBytes = 16;
const int _hashBytes = 32;

/// True when [pin] is exactly [kProfilePinLength] ASCII digits.
bool isValidProfilePin(String pin) {
  if (pin.length != kProfilePinLength) return false;
  for (final unit in pin.codeUnits) {
    if (unit < 0x30 || unit > 0x39) return false;
  }
  return true;
}

/// Shape check for a stored verifier: `pbkdf2-sha256$<iterations>$<salt>$<hash>`
/// with base64 salt/hash of the expected lengths.
///
/// A verifier this build cannot parse is **not** treated as "no PIN" — see
/// [verifyProfilePin].
bool isProfilePinVerifier(String value) => _parse(value) != null;

/// Derive a storable verifier for [pin].
///
/// [salt] and [iterations] are injectable so tests can pin a known vector;
/// production callers pass neither and get a fresh random salt.
String hashProfilePin(
  String pin, {
  List<int>? salt,
  int iterations = kProfilePinIterations,
}) {
  if (!isValidProfilePin(pin)) {
    throw ArgumentError.value(pin, 'pin', 'must be $kProfilePinLength digits');
  }
  if (iterations < 1) {
    throw ArgumentError.value(iterations, 'iterations', 'must be >= 1');
  }
  final s = salt == null ? _randomSalt() : Uint8List.fromList(salt);
  final dk = _pbkdf2Sha256(utf8.encode(pin), s, iterations, _hashBytes);
  return '$_algorithm\$$iterations\$${base64.encode(s)}\$${base64.encode(dk)}';
}

/// Whether [pin] opens [verifier].
///
/// **Fails closed on anything it cannot parse.** A verifier written by a newer
/// build (a stronger algorithm, a longer PIN) must leave the profile locked
/// rather than open: reading an unknown format as "no PIN set" would turn every
/// forward-compatible change into a silent removal of the gate on every older
/// install. The caller distinguishes the two cases with [isProfilePinVerifier]
/// so it can say *why* the PIN won't work.
bool verifyProfilePin(String pin, String verifier) {
  final parsed = _parse(verifier);
  if (parsed == null) return false;
  if (!isValidProfilePin(pin)) return false;
  final dk = _pbkdf2Sha256(
    utf8.encode(pin),
    parsed.salt,
    parsed.iterations,
    parsed.hash.length,
  );
  return _constantTimeEquals(dk, parsed.hash);
}

class _Parsed {
  final int iterations;
  final Uint8List salt;
  final Uint8List hash;
  const _Parsed(this.iterations, this.salt, this.hash);
}

_Parsed? _parse(String value) {
  if (value.isEmpty || value.length > kProfilePinVerifierMaxLength) return null;
  final parts = value.split(r'$');
  if (parts.length != 4) return null;
  if (parts[0] != _algorithm) return null;
  final iterations = int.tryParse(parts[1]);
  // An absurd iteration count is a denial of service against the device that
  // has to verify it, so the parse — not the caller — bounds it.
  if (iterations == null || iterations < 1 || iterations > 1000000) return null;
  try {
    final salt = base64.decode(parts[2]);
    final hash = base64.decode(parts[3]);
    if (salt.length < 8 || salt.length > 64) return null;
    if (hash.length != _hashBytes) return null;
    return _Parsed(
      iterations,
      Uint8List.fromList(salt),
      Uint8List.fromList(hash),
    );
  } on FormatException {
    return null;
  }
}

Uint8List _randomSalt() {
  final rng = Random.secure();
  return Uint8List.fromList([
    for (var i = 0; i < _saltBytes; i++) rng.nextInt(256),
  ]);
}

/// PBKDF2-HMAC-SHA-256 (RFC 8018). [dkLen] is never more than one hash block
/// here, so the loop below is the single-block case written out; pinned against
/// a published vector in `test/profile_pin_test.dart`, which is what keeps this
/// byte-identical to the panel's WebCrypto derivation.
Uint8List _pbkdf2Sha256(
  List<int> password,
  List<int> salt,
  int iterations,
  int dkLen,
) {
  final hmac = Hmac(sha256, password);
  final out = Uint8List(dkLen);
  var offset = 0;
  var block = 1;
  while (offset < dkLen) {
    final seed = <int>[
      ...salt,
      (block >> 24) & 0xff,
      (block >> 16) & 0xff,
      (block >> 8) & 0xff,
      block & 0xff,
    ];
    var u = Uint8List.fromList(hmac.convert(seed).bytes);
    final acc = Uint8List.fromList(u);
    for (var i = 1; i < iterations; i++) {
      u = Uint8List.fromList(hmac.convert(u).bytes);
      for (var j = 0; j < acc.length; j++) {
        acc[j] ^= u[j];
      }
    }
    final take = (dkLen - offset) < acc.length ? (dkLen - offset) : acc.length;
    out.setRange(offset, offset + take, acc);
    offset += take;
    block++;
  }
  return out;
}

bool _constantTimeEquals(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}
