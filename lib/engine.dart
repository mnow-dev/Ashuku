import 'dart:async';

import 'package:flutter/services.dart';

/// Metadata for a video file, as read by the native side.
class VideoInfo {
  VideoInfo.fromMap(Map<dynamic, dynamic> m)
    : path = m['path'] as String,
      name = m['name'] as String,
      width = m['width'] as int,
      height = m['height'] as int,
      durationMs = m['durationMs'] as int,
      fps = (m['fps'] as num?)?.toDouble(),
      bitrate = m['bitrate'] as int?,
      sizeBytes = m['sizeBytes'] as int,
      hasAudio = m['hasAudio'] as bool,
      hasVideo = m['hasVideo'] as bool,
      isHdr = m['isHdr'] as bool,
      videoMime = m['videoMime'] as String?;

  final String path;
  final String name;

  /// Display dimensions, i.e. with rotation already applied.
  final int width;
  final int height;
  final int durationMs;
  final double? fps;
  final int? bitrate;
  final int sizeBytes;
  final bool hasAudio;
  final bool hasVideo;
  final bool isHdr;
  final String? videoMime;

  int get shortSide => width < height ? width : height;
  double get aspectRatio => height == 0 ? 16 / 9 : width / height;
}

class CompressException implements Exception {
  CompressException(this.code, this.message);
  final String code;
  final String? message;
  bool get cancelled => code == 'CANCELLED';
  @override
  String toString() => message ?? code;
}

/// Thin wrapper over the `ashuku/video` platform channel (see VideoEngine.kt).
class Engine {
  Engine._() {
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'progress':
          _progress.add((call.arguments as num).toDouble());
        case 'incomingShare':
          _incoming.add(null);
      }
    });
  }

  static final instance = Engine._();

  static const _channel = MethodChannel('ashuku/video');
  final _progress = StreamController<double>.broadcast();
  final _incoming = StreamController<void>.broadcast();

  /// Export progress in 0..1 for the running [compress] call.
  Stream<double> get progress => _progress.stream;

  /// Fires when a video is shared into the app while it's running.
  Stream<void> get incomingShares => _incoming.stream;

  Future<VideoInfo> probe(String path) async {
    final m = await _channel.invokeMethod<Map>('probe', {'path': path});
    return VideoInfo.fromMap(m!);
  }

  Future<List<Uint8List>> thumbnails(String path, {int count = 10, int height = 96}) async {
    final list = await _channel.invokeMethod<List>('thumbnails', {
      'path': path,
      'count': count,
      'height': height,
    });
    return list!.cast<Uint8List>();
  }

  Future<VideoInfo> compress({
    required String path,
    required int startMs,
    required int endMs,
    required int width,
    required int height,
    required int videoBitrate,
    required int audioBitrate,
    required double targetFps,
    required double sourceFps,
    required bool mute,
  }) async {
    try {
      final m = await _channel.invokeMethod<Map>('compress', {
        'path': path,
        'startMs': startMs,
        'endMs': endMs,
        'width': width,
        'height': height,
        'videoBitrate': videoBitrate,
        'audioBitrate': audioBitrate,
        'targetFps': targetFps,
        'sourceFps': sourceFps,
        'mute': mute,
      });
      return VideoInfo.fromMap(m!);
    } on PlatformException catch (e) {
      throw CompressException(e.code, e.message);
    }
  }

  Future<void> cancel() => _channel.invokeMethod('cancel');

  Future<String> saveToGallery(String path) async =>
      (await _channel.invokeMethod<String>('saveToGallery', {'path': path}))!;

  /// Sends [paths] to [activity] in [package] if it accepts them, else anywhere in [package],
  /// else via the system chooser. Returns true if it went straight to the app.
  Future<bool> share(List<String> paths, {String? package, String? activity}) async => (await _channel
      .invokeMethod<bool>('share', {'paths': paths, 'package': package, 'activity': activity}))!;

  /// Whether [package] (or its [activity]) accepts several videos in one share.
  Future<bool> canSendMultiple(String package, {String? activity}) async =>
      (await _channel.invokeMethod<bool>('canSendMultiple', {'package': package, 'activity': activity}))!;

  Future<Set<String>> installedPackages(List<String> packages) async {
    final list = await _channel.invokeMethod<List>('installedPackages', {'packages': packages});
    return list!.cast<String>().toSet();
  }

  /// Path of a video shared into the app (copied to cache), if one is waiting.
  Future<String?> consumeIncomingShare() => _channel.invokeMethod<String>('consumeIncomingShare');

  Future<void> cleanup() => _channel.invokeMethod('cleanup');

  Future<MediaAccess> mediaAccess() async =>
      MediaAccess.values.byName((await _channel.invokeMethod<String>('mediaAccess'))!);

  /// Shows the system permission dialog (or the "select videos" sheet on Android 14+).
  Future<MediaAccess> requestMediaAccess() async =>
      MediaAccess.values.byName((await _channel.invokeMethod<String>('requestMediaAccess'))!);

  Future<void> openAppSettings() => _channel.invokeMethod('openAppSettings');

  Future<List<Album>> albums() async {
    final list = await _channel.invokeMethod<List>('albums');
    return [for (final m in list!) Album.fromMap(m as Map)];
  }

  /// Videos in [album], or all videos, newest first.
  Future<List<LibraryVideo>> videos({int? album}) async {
    final list = await _channel.invokeMethod<List>('videos', {'bucketId': album});
    return [for (final m in list!) LibraryVideo.fromMap(m as Map)];
  }

  Future<Uint8List> libraryThumbnail(int id, int size) async =>
      (await _channel.invokeMethod<Uint8List>('libraryThumbnail', {'id': id, 'size': size}))!;

  /// A readable file path for a library video (the original file when possible).
  Future<String> libraryPath(int id) async =>
      (await _channel.invokeMethod<String>('libraryPath', {'id': id}))!;
}

enum MediaAccess {
  full,

  /// Android 14+: the user shared only some videos.
  partial,
  denied,

  /// Denied and Android won't ask again; only Settings can change it.
  blocked;

  bool get granted => this == full || this == partial;
}

class Album {
  Album.fromMap(Map<dynamic, dynamic> m)
    : id = m['id'] as int,
      name = m['name'] as String,
      count = m['count'] as int,
      isCamera = m['isCamera'] as bool;

  final int id;
  final String name;
  final int count;
  final bool isCamera;
}

/// A video from MediaStore, before it's opened and probed.
class LibraryVideo {
  LibraryVideo.fromMap(Map<dynamic, dynamic> m)
    : id = m['id'] as int,
      uri = m['uri'] as String,
      name = m['name'] as String? ?? 'video',
      durationMs = m['durationMs'] as int,
      sizeBytes = m['sizeBytes'] as int,
      width = m['width'] as int,
      height = m['height'] as int,
      dateTaken = DateTime.fromMillisecondsSinceEpoch(m['dateTaken'] as int);

  final int id;
  final String uri;
  final String name;
  final int durationMs;
  final int sizeBytes;
  final int width;
  final int height;
  final DateTime dateTaken;

  double? get aspectRatio => width > 0 && height > 0 ? width / height : null;

  @override
  bool operator ==(Object other) => other is LibraryVideo && other.id == id;

  @override
  int get hashCode => id.hashCode;
}
