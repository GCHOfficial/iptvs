import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/diagnostics_log.dart';
import 'package:iptvs/data/renderer_class.dart';

void main() {
  final log = DiagnosticsLog.instance;

  setUp(log.clear);
  tearDown(() {
    debugSetRenderer(null);
    log.clear();
  });

  test('the startup line is exactly what the emulator driver greps for', () async {
    // `tool/android_tv_emulator_check.sh` asserts on
    // `[iptvs.library] renderer=skia-gl reason=forced-debug`, and the renderer
    // leg of `android-tv-emulator.yml` hard-fails on a mismatch. The scope and
    // the two `key=value` runs are therefore a contract, not a log message.
    debugSetRenderer(
      const RendererInfo(renderer: 'skia-gl', reason: 'forced-debug'),
    );
    await reportRenderer();

    final entry = log.entries.single;
    expect(entry.scope, 'library');
    expect(entry.message, 'renderer=skia-gl reason=forced-debug');
  });

  test('a denylist hit names the SoC it matched', () async {
    debugSetRenderer(
      const RendererInfo(renderer: 'skia-gl', reason: 'soc:RTD2875P'),
    );
    await reportRenderer();
    expect(log.entries.single.message, 'renderer=skia-gl reason=soc:RTD2875P');
  });

  test('an unanswered platform leaves no line at all', () async {
    // Off Android — and on an older build whose `iptvs/device` channel has no
    // `renderer` method — there is no decision to report. A line saying
    // "unknown" would read as a renderer this build chose.
    await reportRenderer();
    expect(log.entries, isEmpty);
  });
}
