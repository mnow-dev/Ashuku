import 'dart:math';

import 'package:flutter/material.dart';

import 'engine.dart';

/// A target app and the limits we encode for.
///
/// Sizes use decimal megabytes (1 MB = 1,000,000 bytes), which is slightly
/// stricter than the MiB some apps actually enforce.
class Preset {
  const Preset({
    required this.id,
    required this.name,
    required this.icon,
    required this.color,
    required this.limitMb,
    required this.maxShortSide,
    required this.maxVideoKbps,
    required this.notes,
    this.maxFps = 30,
    this.audioKbps = 128,
    this.maxDurationSec,
    this.package,
    this.shareActivity,
    String? appName,
  }) : _appName = appName;

  final String id;
  final String name;
  final IconData icon;
  final Color color;

  /// Hard file-size limit of the target app.
  final double limitMb;

  /// Largest resolution worth sending (short side, e.g. 720 for 720p).
  final int maxShortSide;

  /// Bitrate ceiling at 1080p30; scaled down for smaller outputs. Keeps short
  /// clips from being needlessly large when the size budget is generous.
  final int maxVideoKbps;
  final int maxFps;
  final int audioKbps;

  /// Longest clip the app accepts, if it has a limit.
  final int? maxDurationSec;

  /// Android package to send the result to directly.
  final String? package;

  /// Specific share target inside [package] (e.g. Instagram's DM vs Reel
  /// handler). These are app internals, so we fall back to the package.
  final String? shareActivity;
  final String notes;

  /// Name of the app [package] belongs to, if it differs from [name].
  final String? _appName;
  String get appName => _appName ?? name;

  String get summary {
    final parts = ['≤ ${formatMb(limitMb)}', '${maxShortSide}p', '$maxFps fps'];
    if (maxDurationSec != null) parts.add('≤ ${maxDurationSec}s');
    return parts.join(' · ');
  }
}

const presets = <Preset>[
  Preset(
    id: 'messenger',
    name: 'Messenger',
    icon: Icons.forum_rounded,
    color: Color(0xFF0A7CFF),
    limitMb: 25,
    maxShortSide: 720,
    maxVideoKbps: 5000,
    audioKbps: 96,
    package: 'com.facebook.orca',
    shareActivity: 'com.facebook.messenger.intents.ShareIntentHandler',
    notes:
        'Messenger attachments are capped at 25 MB (Meta has been rolling out '
        '100 MB, but not everywhere). Messenger re-compresses videos anyway, '
        'so 720p looks the same and uploads faster.',
  ),
  Preset(
    id: 'google_chat',
    name: 'Google Chat',
    icon: Icons.chat_rounded,
    color: Color(0xFF00AC47),
    limitMb: 200,
    maxShortSide: 1080,
    maxVideoKbps: 8000,
    package: 'com.google.android.apps.dynamite',
    notes:
        'Google Chat accepts attachments up to 200 MB; anything larger '
        'has to go through a Drive link.',
  ),
  Preset(
    id: 'instagram_dm',
    name: 'Instagram DM',
    icon: Icons.send_rounded,
    color: Color(0xFFE1306C),
    limitMb: 25,
    maxShortSide: 1080,
    maxVideoKbps: 6000,
    audioKbps: 96,
    maxDurationSec: 60,
    package: 'com.instagram.android',
    shareActivity: 'com.instagram.direct.share.handler.DirectExternalMediaShareActivityVideo',
    appName: 'Instagram',
    notes:
        'Instagram Direct video attachments are limited to about 25 MB '
        'and 60 seconds.',
  ),
  Preset(
    id: 'instagram_reel',
    name: 'Instagram Reel',
    icon: Icons.movie_filter_rounded,
    color: Color(0xFFC13584),
    limitMb: 1000,
    maxShortSide: 1080,
    maxVideoKbps: 10000,
    maxDurationSec: 180,
    package: 'com.instagram.android',
    shareActivity: 'com.instagram.share.handleractivity.ReelShareHandlerActivity',
    appName: 'Instagram',
    notes:
        'Reels take up to 3 minutes at 1080×1920, 30 fps; Stories split '
        'clips into 60 s parts. Instagram re-encodes on upload, so we send '
        'a high-bitrate 1080p file for the best result.',
  ),
  Preset(
    id: 'custom',
    name: 'Custom',
    icon: Icons.tune_rounded,
    color: Color(0xFF7C7C8A),
    limitMb: 50,
    maxShortSide: 1080,
    maxVideoKbps: 8000,
    notes: 'Set your own size limit, resolution and frame rate below.',
  ),
];

/// User-adjustable settings; start from a preset's defaults.
class EncodeOptions {
  const EncodeOptions({
    required this.limitMb,
    required this.resolution,
    required this.fps,
    required this.mute,
  });

  factory EncodeOptions.of(Preset p) =>
      EncodeOptions(limitMb: p.limitMb, resolution: null, fps: p.maxFps, mute: false);

  final double limitMb;

  /// Short side in pixels, or null to pick automatically.
  final int? resolution;
  final int fps;
  final bool mute;

  EncodeOptions copyWith({double? limitMb, int? Function()? resolution, int? fps, bool? mute}) =>
      EncodeOptions(
        limitMb: limitMb ?? this.limitMb,
        resolution: resolution != null ? resolution() : this.resolution,
        fps: fps ?? this.fps,
        mute: mute ?? this.mute,
      );
}

class PlanWarning {
  const PlanWarning(this.text, {this.fitDurationSec});
  final String text;

  /// When set, the UI offers to shorten the trim range to this many seconds.
  final int? fitDurationSec;
}

class EncodePlan {
  const EncodePlan({
    required this.width,
    required this.height,
    required this.fps,
    required this.videoKbps,
    required this.audioKbps,
    required this.startMs,
    required this.endMs,
    required this.limitBytes,
    required this.warnings,
  });

  final int width;
  final int height;
  final double fps;
  final int videoKbps;
  final int audioKbps;
  final int startMs;
  final int endMs;
  final int limitBytes;
  final List<PlanWarning> warnings;

  int get durationMs => endMs - startMs;

  int get estimatedBytes => ((videoKbps + audioKbps) * 1000 / 8 * durationMs / 1000).round();
}

/// Standard short-side sizes we step through when the size budget is tight.
const resolutionRungs = [2160, 1440, 1080, 720, 540, 480, 360, 240];

/// Headroom for container overhead and encoder bitrate overshoot.
const _sizeSafety = 0.92;

/// Below this many bits per pixel H.264 gets visibly blocky, so auto mode
/// prefers a smaller resolution instead.
const _minBitsPerPixel = 0.075;

EncodePlan makePlan({
  required VideoInfo source,
  required Preset preset,
  required EncodeOptions options,
  required int startMs,
  required int endMs,
  double bitrateScale = 1,
}) {
  final durationMs = max(100, endMs - startMs);
  final durationSec = durationMs / 1000;
  final sourceFps = source.fps ?? 30;
  final fps = min(sourceFps, options.fps.toDouble());
  final limitBytes = (options.limitMb * 1e6).round();
  final budgetKbps = limitBytes * 8 / 1000 / durationSec * _sizeSafety;

  var audioKbps = (options.mute || !source.hasAudio) ? 0 : preset.audioKbps;
  if (audioKbps > 0 && budgetKbps < audioKbps * 6) {
    // Long clip into a small limit: give the picture most of the bits.
    audioKbps = (budgetKbps * 0.15).clamp(32, audioKbps).round();
  }
  final videoBudgetKbps = budgetKbps - audioKbps;

  final top = min(options.resolution ?? preset.maxShortSide, source.shortSide);
  final candidates = [top, if (options.resolution == null) ...resolutionRungs.where((r) => r < top)];

  late int width, height, videoKbps;
  for (final (i, rung) in candidates.indexed) {
    (width, height) = _scaledSize(source, rung);
    final pixelsPerSec = width * height * fps;
    final capKbps = max(300.0, preset.maxVideoKbps * pow(pixelsPerSec / (1920 * 1080 * 30), 0.75));
    videoKbps = (min(capKbps, videoBudgetKbps) * bitrateScale).round().clamp(100, 100000);
    final bpp = videoKbps * 1000 / pixelsPerSec;
    if (bpp >= _minBitsPerPixel || i == candidates.length - 1) break;
  }

  final warnings = <PlanWarning>[];
  final maxDuration = preset.maxDurationSec;
  if (maxDuration != null && durationSec > maxDuration + 0.05) {
    warnings.add(
      PlanWarning(
        '${preset.name} takes clips up to ${maxDuration}s — this one is ${formatDuration(durationMs)}.',
        fitDurationSec: maxDuration,
      ),
    );
  }
  if (videoKbps < 400 && videoBudgetKbps < 400) {
    warnings.add(
      const PlanWarning(
        'Very low bitrate for this length — trim the clip or raise the size limit for better quality.',
      ),
    );
  }
  if (source.isHdr) {
    warnings.add(const PlanWarning('HDR video will be converted to SDR so it plays correctly in chats.'));
  }

  return EncodePlan(
    width: width,
    height: height,
    fps: fps,
    videoKbps: videoKbps,
    audioKbps: audioKbps,
    startMs: startMs,
    endMs: endMs,
    limitBytes: limitBytes,
    warnings: warnings,
  );
}

/// Output size for a target short side, keeping aspect ratio and capping the
/// long side at 16:9 so tall screen recordings don't blow the budget.
(int, int) _scaledSize(VideoInfo source, int shortSide) {
  final long = max(source.width, source.height);
  final scale = [1.0, shortSide / source.shortSide, (shortSide * 16 / 9) / long].reduce(min);
  int even(double v) => max(2, (v / 2).round() * 2);
  return (even(source.width * scale), even(source.height * scale));
}

String formatMb(double mb) =>
    mb >= 1000 ? '${(mb / 1000).toStringAsFixed(mb % 1000 == 0 ? 0 : 1)} GB' : '${mb.round()} MB';

String formatBytes(int bytes) {
  if (bytes >= 1e9) return '${(bytes / 1e9).toStringAsFixed(2)} GB';
  if (bytes >= 1e6) return '${(bytes / 1e6).toStringAsFixed(bytes >= 1e8 ? 0 : 1)} MB';
  return '${(bytes / 1e3).toStringAsFixed(0)} KB';
}

String formatKbps(num kbps) =>
    kbps >= 1000 ? '${(kbps / 1000).toStringAsFixed(1)} Mbps' : '${kbps.round()} kbps';

String formatDuration(int ms, {bool tenths = true}) {
  final totalSec = ms / 1000;
  final m = totalSec ~/ 60;
  final s = totalSec - m * 60;
  final secText = tenths ? s.toStringAsFixed(1).padLeft(4, '0') : s.floor().toString().padLeft(2, '0');
  return '$m:$secText';
}
