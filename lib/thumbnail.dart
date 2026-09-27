import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import 'engine.dart';

/// Loads a MediaStore thumbnail (the system's cached one) for a library video.
@immutable
class MediaThumbnail extends ImageProvider<MediaThumbnail> {
  const MediaThumbnail(this.id, {this.size = 320});

  final int id;
  final int size;

  @override
  Future<MediaThumbnail> obtainKey(ImageConfiguration configuration) => SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(MediaThumbnail key, ImageDecoderCallback decode) =>
      OneFrameImageStreamCompleter(_load(decode));

  Future<ImageInfo> _load(ImageDecoderCallback decode) async {
    final bytes = await Engine.instance.libraryThumbnail(id, size);
    final codec = await decode(await ui.ImmutableBuffer.fromUint8List(bytes));
    final frame = await codec.getNextFrame();
    return ImageInfo(image: frame.image);
  }

  @override
  bool operator ==(Object other) => other is MediaThumbnail && other.id == id && other.size == size;

  @override
  int get hashCode => Object.hash(id, size);
}

/// A still frame from a video file on disk (e.g. a compressed output).
@immutable
class FileVideoThumbnail extends ImageProvider<FileVideoThumbnail> {
  const FileVideoThumbnail(this.path, {this.height = 160});

  final String path;
  final int height;

  @override
  Future<FileVideoThumbnail> obtainKey(ImageConfiguration configuration) => SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(FileVideoThumbnail key, ImageDecoderCallback decode) =>
      OneFrameImageStreamCompleter(_load(decode));

  Future<ImageInfo> _load(ImageDecoderCallback decode) async {
    final frames = await Engine.instance.thumbnails(path, count: 1, height: height);
    final codec = await decode(await ui.ImmutableBuffer.fromUint8List(frames.first));
    final frame = await codec.getNextFrame();
    return ImageInfo(image: frame.image);
  }

  @override
  bool operator ==(Object other) =>
      other is FileVideoThumbnail && other.path == path && other.height == height;

  @override
  int get hashCode => Object.hash(path, height);
}
