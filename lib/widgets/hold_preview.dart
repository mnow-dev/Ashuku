import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

import '../presets.dart';

/// What to play while a thumbnail is held: a file [path] or a content [uri].
class PreviewSource {
  const PreviewSource({this.path, this.uri, this.placeholder, this.aspectRatio, this.caption})
    : assert(path != null || uri != null);

  final String? path;
  final String? uri;

  /// Shown until the first video frame is ready.
  final ImageProvider? placeholder;
  final double? aspectRatio;
  final String? caption;
}

/// Plays [source] with sound in a pop-over for as long as [child] is pressed.
///
/// Sliding sideways while holding scrubs: the finger's horizontal position on
/// screen maps to an absolute point in the video (left edge = start, right
/// edge = end).
class HoldToPreview extends StatefulWidget {
  const HoldToPreview({super.key, required this.source, required this.child, this.onTap});

  final PreviewSource source;
  final Widget child;
  final VoidCallback? onTap;

  @override
  State<HoldToPreview> createState() => _HoldToPreviewState();
}

class _HoldToPreviewState extends State<HoldToPreview> {
  /// How far the finger must slide before scrubbing starts, so the natural
  /// wobble of a held finger doesn't jump the video.
  static const _scrubSlop = 16.0;

  /// Inset from the screen edges where scrubbing reaches 0% / 100%.
  static const _scrubMargin = 32.0;

  OverlayEntry? _entry;

  /// Scrub position in 0..1, or null while not scrubbing.
  final _scrub = ValueNotifier<double?>(null);
  double _pressX = 0;

  void _show(LongPressStartDetails details) {
    _hide();
    _pressX = details.globalPosition.dx;
    _scrub.value = null;
    HapticFeedback.mediumImpact();
    _entry = OverlayEntry(
      builder: (_) => _PeekView(source: widget.source, scrub: _scrub),
    );
    Overlay.of(context, rootOverlay: true).insert(_entry!);
  }

  void _move(LongPressMoveUpdateDetails details) {
    final x = details.globalPosition.dx;
    if (_scrub.value == null) {
      if ((x - _pressX).abs() < _scrubSlop) return;
      HapticFeedback.selectionClick();
    }
    final width = MediaQuery.sizeOf(context).width;
    _scrub.value = ((x - _scrubMargin) / (width - 2 * _scrubMargin)).clamp(0.0, 1.0);
  }

  void _hide() {
    _entry
      ?..remove()
      ..dispose();
    _entry = null;
  }

  @override
  void dispose() {
    _hide();
    _scrub.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Raw pointer events guarantee the preview closes however the press ends.
    return Listener(
      onPointerUp: (_) => _hide(),
      onPointerCancel: (_) => _hide(),
      child: GestureDetector(
        onTap: widget.onTap,
        onLongPressStart: _show,
        onLongPressMoveUpdate: _move,
        child: widget.child,
      ),
    );
  }
}

class _PeekView extends StatefulWidget {
  const _PeekView({required this.source, required this.scrub});
  final PreviewSource source;
  final ValueListenable<double?> scrub;

  @override
  State<_PeekView> createState() => _PeekViewState();
}

class _PeekViewState extends State<_PeekView> with SingleTickerProviderStateMixin {
  late final VideoPlayerController _player;
  late final AnimationController _appear = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 180),
  )..forward();

  /// Latest requested seek target; seeks run one at a time and skip stale ones.
  Duration? _pendingSeek;
  bool _seeking = false;

  /// Resumes playback once the finger has rested for a moment.
  Timer? _resume;

  @override
  void initState() {
    super.initState();
    final source = widget.source;
    _player = source.path != null
        ? VideoPlayerController.file(File(source.path!))
        : VideoPlayerController.contentUri(Uri.parse(source.uri!));
    _player.initialize().then((_) {
      if (!mounted) return;
      _player.setLooping(true);
      if (widget.scrub.value != null) {
        _onScrub();
      } else {
        _player.play();
      }
      setState(() {});
    });
    widget.scrub.addListener(_onScrub);
  }

  @override
  void dispose() {
    widget.scrub.removeListener(_onScrub);
    _resume?.cancel();
    _player.dispose();
    _appear.dispose();
    super.dispose();
  }

  void _onScrub() {
    final fraction = widget.scrub.value;
    if (fraction == null || !_player.value.isInitialized) return;
    // Pause while sliding so audio doesn't stutter; pick up again when the finger rests.
    _player.pause();
    _resume?.cancel();
    _resume = Timer(const Duration(milliseconds: 250), () {
      if (mounted) _player.play();
    });
    _seekTo(_player.value.duration * fraction);
  }

  Future<void> _seekTo(Duration target) async {
    _pendingSeek = target;
    if (_seeking) return;
    _seeking = true;
    while (_pendingSeek != null && mounted) {
      final next = _pendingSeek!;
      _pendingSeek = null;
      await _player.seekTo(next);
    }
    _seeking = false;
  }

  @override
  Widget build(BuildContext context) {
    final source = widget.source;
    final ready = _player.value.isInitialized;
    final aspect = ready ? _player.value.aspectRatio : (source.aspectRatio ?? 9 / 16);
    final curve = CurvedAnimation(parent: _appear, curve: Curves.easeOutCubic);
    return IgnorePointer(
      child: Material(
        type: MaterialType.transparency,
        child: FadeTransition(
          opacity: curve,
          child: Stack(
            fit: StackFit.expand,
            children: [
              BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
                child: const ColoredBox(color: Color(0x99000000)),
              ),
              SafeArea(
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: ScaleTransition(
                      scale: Tween(begin: 0.9, end: 1.0).animate(curve),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          ConstrainedBox(
                            constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.68),
                            child: AspectRatio(
                              aspectRatio: aspect,
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(20),
                                  boxShadow: const [BoxShadow(blurRadius: 24, color: Colors.black54)],
                                ),
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(20),
                                  child: Stack(
                                    fit: StackFit.expand,
                                    children: [
                                      const ColoredBox(color: Colors.black),
                                      if (source.placeholder != null)
                                        Image(image: source.placeholder!, fit: BoxFit.cover),
                                      if (ready) VideoPlayer(_player),
                                      Align(
                                        alignment: Alignment.bottomCenter,
                                        child: _ScrubBar(player: _player, scrub: widget.scrub),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 14),
                          _Caption(player: _player, scrub: widget.scrub, caption: source.caption),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Playback progress; follows the finger directly while scrubbing.
class _ScrubBar extends StatelessWidget {
  const _ScrubBar({required this.player, required this.scrub});
  final VideoPlayerController player;
  final ValueListenable<double?> scrub;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.primary;
    return ListenableBuilder(
      listenable: Listenable.merge([player, scrub]),
      builder: (context, _) {
        final value = player.value;
        final durationMs = value.duration.inMilliseconds;
        final scrubbing = scrub.value != null;
        // Follow the finger while it moves (player paused), live playback once it rests.
        final fraction = scrubbing && !value.isPlaying
            ? scrub.value!
            : (durationMs == 0 ? 0.0 : value.position.inMilliseconds / durationMs);
        return AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          height: scrubbing ? 8 : 3,
          color: Colors.white24,
          alignment: Alignment.centerLeft,
          child: FractionallySizedBox(
            widthFactor: fraction.clamp(0.0, 1.0),
            heightFactor: 1,
            child: ColoredBox(color: color),
          ),
        );
      },
    );
  }
}

/// The video's details, replaced by the scrub time while sliding.
class _Caption extends StatelessWidget {
  const _Caption({required this.player, required this.scrub, required this.caption});
  final VideoPlayerController player;
  final ValueListenable<double?> scrub;
  final String? caption;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([player, scrub]),
      builder: (context, _) {
        final fraction = scrub.value;
        if (fraction != null) {
          final value = player.value;
          final durationMs = value.duration.inMilliseconds;
          final positionMs = value.isPlaying
              ? value.position.inMilliseconds
              : (durationMs * fraction).round();
          return DecoratedBox(
            decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(16)),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
              child: Text(
                '${formatDuration(positionMs)} / ${formatDuration(durationMs, tenths: false)}',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
            ),
          );
        }
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (caption != null)
              Text(
                caption!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white, fontSize: 14),
              ),
            const SizedBox(height: 4),
            const Text('Slide left or right to scrub', style: TextStyle(color: Colors.white60, fontSize: 12)),
          ],
        );
      },
    );
  }
}
