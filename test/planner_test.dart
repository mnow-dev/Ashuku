import 'package:ashuku/engine.dart';
import 'package:ashuku/presets.dart';
import 'package:flutter_test/flutter_test.dart';

VideoInfo video({int w = 1920, int h = 1080, int ms = 30000, double fps = 30, bool audio = true}) =>
    VideoInfo.fromMap({
      'path': '/x.mp4',
      'name': 'x.mp4',
      'width': w,
      'height': h,
      'durationMs': ms,
      'fps': fps,
      'bitrate': 20000000,
      'sizeBytes': 100000000,
      'hasAudio': audio,
      'hasVideo': true,
      'isHdr': false,
    });

Preset preset(String id) => presets.firstWhere((p) => p.id == id);

EncodePlan plan(VideoInfo v, Preset p, {EncodeOptions? o, int? endMs}) => makePlan(
  source: v,
  preset: p,
  options: o ?? EncodeOptions.of(p),
  startMs: 0,
  endMs: endMs ?? v.durationMs,
);

void main() {
  test('estimate stays under the limit for long clips', () {
    for (final p in presets) {
      for (final ms in [5000, 60000, 300000, 900000]) {
        final r = plan(video(ms: ms), p);
        expect(r.estimatedBytes, lessThanOrEqualTo(r.limitBytes), reason: '${p.id} $ms');
      }
    }
  });

  test('messenger caps at 720p and 30 fps', () {
    final r = plan(video(w: 3840, h: 2160, fps: 60, ms: 10000), preset('messenger'));
    expect((r.width, r.height), (1280, 720));
    expect(r.fps, 30);
  });

  test('portrait keeps orientation and even dimensions', () {
    final r = plan(video(w: 1080, h: 1920, ms: 10000), preset('messenger'));
    expect((r.width, r.height), (720, 1280));
    final odd = plan(video(w: 1082, h: 2402, ms: 10000), preset('google_chat'));
    expect(odd.width.isEven && odd.height.isEven, isTrue);
    expect(odd.height, lessThanOrEqualTo(1920));
  });

  test('auto resolution steps down when the budget is tight', () {
    final short = plan(video(ms: 10000), preset('instagram_dm'));
    final long = plan(video(ms: 60000), preset('instagram_dm'));
    expect(short.height, 1080);
    expect(long.height, lessThan(1080));
  });

  test('manual resolution is respected', () {
    final p = preset('google_chat');
    final r = plan(video(ms: 600000), p, o: EncodeOptions.of(p).copyWith(resolution: () => 1080));
    expect(r.height, 1080);
  });

  test('never upscales', () {
    final r = plan(video(w: 640, h: 360, ms: 5000), preset('google_chat'));
    expect((r.width, r.height), (640, 360));
  });

  test('warns about Instagram DM length and offers a fit', () {
    final r = plan(video(ms: 90000), preset('instagram_dm'));
    expect(r.warnings.any((w) => w.fitDurationSec == 60), isTrue);
    expect(plan(video(ms: 90000), preset('instagram_dm'), endMs: 60000).warnings, isEmpty);
  });

  test('mute or silent source drops audio bitrate', () {
    final p = preset('messenger');
    expect(plan(video(), p, o: EncodeOptions.of(p).copyWith(mute: true)).audioKbps, 0);
    expect(plan(video(audio: false), p).audioKbps, 0);
  });
}
