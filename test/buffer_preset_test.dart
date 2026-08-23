import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/player/buffer_preset.dart';
import 'package:iptvs/player/mpv_options.dart';
import 'package:iptvs/sources/source_config.dart';

SourceConfig _config({String? preset}) => SourceConfig(
  id: 'src1',
  kind: SourceKind.m3u,
  label: 'One',
  fields: const {'playlistUrl': 'http://example.test/list.m3u'},
  settings: {'bufferPreset': ?preset},
);

void main() {
  group('bufferPresetFromName', () {
    test('parses the three names, case-insensitively', () {
      expect(bufferPresetFromName('low'), BufferPreset.low);
      expect(bufferPresetFromName('LOW'), BufferPreset.low);
      expect(bufferPresetFromName('normal'), BufferPreset.normal);
      expect(bufferPresetFromName('high'), BufferPreset.high);
    });

    test('anything else is normal', () {
      // Including a value a newer build wrote — the same fallback the Kotlin
      // side applies, so an unknown name degrades to the default rather than
      // to an arbitrary preset.
      expect(bufferPresetFromName(null), BufferPreset.normal);
      expect(bufferPresetFromName(''), BufferPreset.normal);
      expect(bufferPresetFromName('enormous'), BufferPreset.normal);
    });

    test('round-trips through storageName', () {
      for (final preset in BufferPreset.values) {
        expect(bufferPresetFromName(preset.storageName), preset);
      }
    });
  });

  group('nextBufferPreset', () {
    test('cycles low -> normal -> high -> low', () {
      expect(nextBufferPreset(BufferPreset.low), BufferPreset.normal);
      expect(nextBufferPreset(BufferPreset.normal), BufferPreset.high);
      expect(nextBufferPreset(BufferPreset.high), BufferPreset.low);
    });

    test('visits every preset in one full cycle', () {
      var preset = BufferPreset.normal;
      final seen = <BufferPreset>{};
      for (var i = 0; i < BufferPreset.values.length; i++) {
        seen.add(preset);
        preset = nextBufferPreset(preset);
      }
      expect(seen, BufferPreset.values.toSet());
      expect(preset, BufferPreset.normal, reason: 'returns to the start');
    });
  });

  group('mpvBufferOptions', () {
    test('normal changes nothing, so an untouched source runs as before', () {
      // The point of an empty map: mpv's own defaults are what every build so
      // far has used, and "normal" must mean exactly that rather than a tuning
      // that merely resembles it.
      expect(mpvBufferOptions(BufferPreset.normal), isEmpty);
    });

    test('low and high set the cache depth, and nothing else', () {
      for (final preset in [BufferPreset.low, BufferPreset.high]) {
        expect(mpvBufferOptions(preset).keys, ['cache-secs']);
      }
    });

    test('the preset never touches demuxer-max-bytes', () {
      // media_kit already owns it via `PlayerConfiguration.bufferSize`, and
      // this app sets it *per surface* — 64 MB for the fullscreen player,
      // media_kit's own default for the preview. Setting it from the preset
      // would override two deliberate, different choices with one, and would
      // retune the VOD cache (sized for seek smoothness) from a control whose
      // UI talks about playback stability.
      for (final preset in BufferPreset.values) {
        expect(
          mpvBufferOptions(preset).containsKey('demuxer-max-bytes'),
          isFalse,
          reason: '$preset must leave the byte cap to media_kit',
        );
      }
    });

    test('cache depth grows with the preset', () {
      int secs(BufferPreset p) =>
          int.parse(mpvBufferOptions(p)['cache-secs'] ?? '10');
      expect(secs(BufferPreset.low), lessThan(secs(BufferPreset.normal)));
      expect(secs(BufferPreset.normal), lessThan(secs(BufferPreset.high)));
    });

    test('never collides with a key kLiveMpvOptions already owns', () {
      // Both maps are merged into one, preset last. A shared key would mean the
      // preset silently overriding resilience tuning it knows nothing about.
      for (final preset in BufferPreset.values) {
        for (final key in mpvBufferOptions(preset).keys) {
          expect(
            kLiveMpvOptions.containsKey(key),
            isFalse,
            reason: '$preset overrides kLiveMpvOptions["$key"]',
          );
        }
      }
    });
  });

  group('SourceConfig.bufferPresetName', () {
    test('defaults to normal when unset', () {
      expect(_config().bufferPresetName, 'normal');
    });

    test('reads a stored preset', () {
      expect(_config(preset: 'low').bufferPresetName, 'low');
      expect(_config(preset: 'high').bufferPresetName, 'high');
    });

    test('an unrecognised stored value reads as normal', () {
      expect(_config(preset: 'enormous').bufferPresetName, 'normal');
      expect(_config(preset: '').bufferPresetName, 'normal');
    });

    test('is case-insensitive about what was stored', () {
      expect(_config(preset: 'HIGH').bufferPresetName, 'high');
    });
  });

  group('labels and hints', () {
    test('every preset has both', () {
      for (final preset in BufferPreset.values) {
        expect(bufferPresetLabel(preset), isNotEmpty);
        expect(bufferPresetHint(preset), isNotEmpty);
      }
    });

    test('the large preset does not promise what a buffer cannot do', () {
      // A deeper buffer converts frequent short stalls into rarer long ones; it
      // adds no bandwidth. Saying so is the difference between a setting and a
      // false promise, and this is the most common misreading of it.
      expect(bufferPresetHint(BufferPreset.high), contains('too slow'));
    });
  });
}
