// The profile PIN verifier format.
//
// This file is the contract three implementations share: this one, the web
// panel's WebCrypto derivation (`panel/src/pin.js`, whose own test asserts the
// same vectors), and Postgres, which checks the *shape* in `profiles_validate`.
// A change here that isn't mirrored in both others silently locks somebody out
// of their own profile.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/profile_pin.dart';

void main() {
  group('isValidProfilePin', () {
    test('accepts exactly four digits', () {
      expect(isValidProfilePin('0000'), isTrue);
      expect(isValidProfilePin('4821'), isTrue);
    });

    test('rejects anything else', () {
      expect(isValidProfilePin(''), isFalse);
      expect(isValidProfilePin('123'), isFalse);
      expect(isValidProfilePin('12345'), isFalse);
      expect(isValidProfilePin('12a4'), isFalse);
      expect(isValidProfilePin('12 4'), isFalse);
      // Non-ASCII digits look like digits and are not.
      expect(isValidProfilePin('١٢٣٤'), isFalse);
    });
  });

  group('PBKDF2-HMAC-SHA-256', () {
    // Cross-checked against an independent PBKDF2-HMAC-SHA-256
    // implementation (CPython's `hashlib.pbkdf2_hmac`, itself agreeing with the
    // published `("password", "salt", 1)` vector `120fb6cf…`). These are what
    // guarantee the derivation below matches WebCrypto's `PBKDF2` in the panel
    // — its test asserts the same two triples.
    test('matches an independent implementation', () {
      String hex(String pin, List<int> salt, int iterations) {
        final encoded = hashProfilePin(
          pin,
          salt: salt,
          iterations: iterations,
        );
        final dk = base64.decode(encoded.split(r'$')[3]);
        return dk.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      }

      expect(
        hex('1234', utf8.encode('salt'), 1),
        'd0bc3a5e5fb06f3cb892c741febf58b7d40d22e79e60125e29bc0e4f354ba842',
      );
      // The production iteration count, so a change to it can't slip through
      // as "the tests still pass".
      expect(
        hex('4821', utf8.encode('0123456789abcdef'), kProfilePinIterations),
        '0a658136fbe7b98473c96f81c7d49908a8468ecf8066f4884f11b3c180e78193',
      );
    });

    test('the same pin and salt derive the same verifier', () {
      final a = hashProfilePin('4821', salt: utf8.encode('0123456789abcdef'));
      final b = hashProfilePin('4821', salt: utf8.encode('0123456789abcdef'));
      expect(a, b);
    });

    test('a fresh salt makes two verifiers for one pin differ', () {
      expect(hashProfilePin('4821'), isNot(hashProfilePin('4821')));
    });
  });

  group('verifyProfilePin', () {
    test('opens with the right pin and not the wrong one', () {
      final verifier = hashProfilePin('4821');
      expect(verifyProfilePin('4821', verifier), isTrue);
      expect(verifyProfilePin('4822', verifier), isFalse);
      expect(verifyProfilePin('1284', verifier), isFalse);
    });

    test('round-trips every digit position', () {
      for (final pin in ['0000', '9999', '1000', '0001']) {
        expect(verifyProfilePin(pin, hashProfilePin(pin)), isTrue, reason: pin);
      }
    });

    test('honours the iteration count recorded in the verifier', () {
      final cheap = hashProfilePin('4821', iterations: 3);
      expect(verifyProfilePin('4821', cheap), isTrue);
    });

    // The forward-compatibility rule: an unreadable verifier leaves the profile
    // locked. Reading it as "no PIN" would turn a future format change into a
    // silent removal of the gate on every older install.
    test('fails closed on a verifier it cannot parse', () {
      for (final bad in [
        '',
        'nonsense',
        r'pbkdf2-sha512$10000$c2FsdHNhbHRzYWx0c2E=$aGFzaA==',
        r'pbkdf2-sha256$0$c2FsdHNhbHRzYWx0c2E=$aGFzaA==',
        r'pbkdf2-sha256$10000$!!!$aGFzaA==',
        r'pbkdf2-sha256$10000$c2FsdA==', // too few fields
      ]) {
        expect(verifyProfilePin('4821', bad), isFalse, reason: bad);
        expect(isProfilePinVerifier(bad), isFalse, reason: bad);
      }
    });

    test('a real verifier is recognised as one', () {
      expect(isProfilePinVerifier(hashProfilePin('4821')), isTrue);
    });

    test('a verifier fits the bound both stores enforce', () {
      expect(
        hashProfilePin('4821').length,
        lessThanOrEqualTo(kProfilePinVerifierMaxLength),
      );
    });
  });

  test('hashing a non-pin is a programming error', () {
    expect(() => hashProfilePin('12345'), throwsArgumentError);
    expect(() => hashProfilePin('abcd'), throwsArgumentError);
  });
}
