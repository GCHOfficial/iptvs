// Parity gate between the Dart secret-key split (lib/data/secret_keys.dart)
// and the SQL strip trigger that enforces broad-only on the cloud rows
// (supabase/migrations/*.sql). A key Dart treats as secret but SQL doesn't
// know about lands in the broadly-readable `sources.fields` /
// `metadata_configs.config` table — that is a real credential leak, not a
// cosmetic drift.
//
// Approach: `20260725000000_secrets_store.sql` is the migration that first
// adds the strip lines to `sources_validate()` / `metadata_validate()`, and it
// is IMMUTABLE (already applied to production) — but a *future* migration is
// free to `create or replace` either function again with a different key
// list. So this test does not hardcode that filename: it scans every file in
// supabase/migrations/ in filename order (the `<timestamp>_<name>.sql` naming
// convention makes lexicographic order equal chronological order) and, for
// each of the two function names, keeps overwriting a "latest body" variable
// every time a `create or replace function public.<name>()` definition is
// found. Whatever body survives after scanning every file — regardless of
// which file it came from — is the definition Postgres actually has, and
// that's what gets checked against the Dart constants.
//
// Extraction is regex-based and deliberately narrow: it looks for the
// `array[...]` literal being subtracted from `new.fields`/`new.config` inside
// that function body. It tolerates whitespace/line-wrapping inside the
// brackets (a future reformat), but requires the literal to actually be
// present — if a future rewrite of the trigger drops the strip entirely, the
// extracted set is empty and the comparison against the non-empty Dart
// constant fails loudly, which is the correct outcome (a silently-removed
// strip is exactly the drift this test exists to catch).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/secret_keys.dart';

/// Scans every `.sql` file under [migrationsDir] in filename order and
/// returns the body (the text between `as $$` and the closing `$$;`) of the
/// LAST `create or replace function public.<functionName>()` definition
/// found, or `null` if the function is never defined.
String? _latestFunctionBody(Directory migrationsDir, String functionName) {
  final files =
      migrationsDir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.toLowerCase().endsWith('.sql'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));

  final funcRegex = RegExp(
    r'create\s+or\s+replace\s+function\s+public\.' +
        RegExp.escape(functionName) +
        r'\s*\(\s*\)[\s\S]*?as\s*\$\$([\s\S]*?)\$\$\s*;',
    caseSensitive: false,
  );

  String? latestBody;
  for (final file in files) {
    final content = file.readAsStringSync();
    for (final match in funcRegex.allMatches(content)) {
      latestBody = match.group(1);
    }
  }
  return latestBody;
}

/// Extracts the key set out of the first `array['a', 'b', ...]` literal found
/// in [functionBody], or `null` if there is none.
Set<String>? _arrayLiteralKeys(String functionBody) {
  final arrayRegex = RegExp(r'array\s*\[([\s\S]*?)\]', caseSensitive: false);
  final match = arrayRegex.firstMatch(functionBody);
  if (match == null) return null;
  final inner = match.group(1)!;
  final itemRegex = RegExp(r"'((?:[^'\\]|\\.)*)'");
  return itemRegex
      .allMatches(inner)
      .map((m) => m.group(1)!)
      .toSet();
}

void main() {
  final migrationsDir = Directory('supabase/migrations');

  test('supabase/migrations directory is present and non-empty', () {
    expect(
      migrationsDir.existsSync(),
      isTrue,
      reason: 'expected ${migrationsDir.path} to exist',
    );
    expect(
      migrationsDir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.toLowerCase().endsWith('.sql')),
      isNotEmpty,
    );
  });

  test(
    'sources_validate() strips exactly kSourceSecretKeys from new.fields',
    () {
      final body = _latestFunctionBody(migrationsDir, 'sources_validate');
      expect(
        body,
        isNotNull,
        reason:
            'no "create or replace function public.sources_validate()" '
            'definition found in any supabase/migrations/*.sql file',
      );
      final sqlKeys = _arrayLiteralKeys(body!);
      expect(
        sqlKeys,
        isNotNull,
        reason:
            'latest sources_validate() body has no array[...] literal to '
            'strip from new.fields — either the strip trigger was removed '
            '(a real leak) or this test\'s extraction regex needs updating '
            'to match a reformatted trigger:\n$body',
      );
      expect(
        sqlKeys,
        kSourceSecretKeys,
        reason:
            'SQL sources_validate() strip list and Dart kSourceSecretKeys '
            'have drifted — a key present on only one side means a secret '
            'either leaks into the broad `sources.fields` cloud row, or a '
            'broad field is wrongly hidden through the secret RPCs.\n'
            'SQL:  $sqlKeys\n'
            'Dart: $kSourceSecretKeys',
      );
    },
  );

  test(
    'metadata_validate() strips exactly kMetadataSecretKeys from new.config',
    () {
      final body = _latestFunctionBody(migrationsDir, 'metadata_validate');
      expect(
        body,
        isNotNull,
        reason:
            'no "create or replace function public.metadata_validate()" '
            'definition found in any supabase/migrations/*.sql file',
      );
      final sqlKeys = _arrayLiteralKeys(body!);
      expect(
        sqlKeys,
        isNotNull,
        reason:
            'latest metadata_validate() body has no array[...] literal to '
            'strip from new.config — either the strip trigger was removed '
            '(a real leak) or this test\'s extraction regex needs updating '
            'to match a reformatted trigger:\n$body',
      );
      expect(
        sqlKeys,
        kMetadataSecretKeys,
        reason:
            'SQL metadata_validate() strip list and Dart kMetadataSecretKeys '
            'have drifted — a key present on only one side means a secret '
            'either leaks into the broad `metadata_configs.config` cloud '
            'row, or a broad field is wrongly hidden through the secret '
            'RPCs.\n'
            'SQL:  $sqlKeys\n'
            'Dart: $kMetadataSecretKeys',
      );
    },
  );
}
