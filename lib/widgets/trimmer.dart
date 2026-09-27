import 'dart:typed_data';

import 'package:flutter/material.dart';

enum TrimHandle { start, end }

/// Filmstrip with draggable start/end handles and a playhead.
///
/// Drag near a handle to move it; drag or tap elsewhere to scrub.
class Trimmer extends StatefulWidget {
  const Trimmer({
    super.key,
    required this.durationMs,
    required this.startMs,
    required this.endMs,
    required this.positionMs,
    required this.thumbnails,
    required this.onTrim,
    required this.onTrimEnd,
    required this.onSeek,
    this.minLengthMs = 300,
  });

  final int durationMs;
  final int startMs;
  final int endMs;
  final int positionMs;
  final List<Uint8List>? thumbnails;
  final void Function(int startMs, int endMs, TrimHandle moved) onTrim;
  final VoidCallback onTrimEnd;
  final ValueChanged<int> onSeek;
  final int minLengthMs;

  @override
  State<Trimmer> createState() => _TrimmerState();
}

class _TrimmerState extends State<Trimmer> {
  static const _handleWidth = 18.0;
  static const _height = 64.0;
  static const _grabDistance = 36.0;

  TrimHandle? _dragging;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        final trackWidth = constraints.maxWidth - 2 * _handleWidth;
        final duration = widget.durationMs.toDouble();
        double xOf(int ms) => _handleWidth + ms / duration * trackWidth;
        int msOf(double x) =>
            ((x - _handleWidth) / trackWidth * duration).round().clamp(0, widget.durationMs);

        final startX = xOf(widget.startMs);
        final endX = xOf(widget.endMs);

        void dragTo(double x) {
          final ms = msOf(x);
          switch (_dragging) {
            case TrimHandle.start:
              widget.onTrim(ms.clamp(0, widget.endMs - widget.minLengthMs), widget.endMs, TrimHandle.start);
            case TrimHandle.end:
              widget.onTrim(
                widget.startMs,
                ms.clamp(widget.startMs + widget.minLengthMs, widget.durationMs),
                TrimHandle.end,
              );
            case null:
              widget.onSeek(ms.clamp(widget.startMs, widget.endMs));
          }
        }

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onHorizontalDragStart: (d) {
            final x = d.localPosition.dx;
            final toStart = (x - (startX - _handleWidth / 2)).abs();
            final toEnd = (x - (endX + _handleWidth / 2)).abs();
            if (toStart <= toEnd && toStart < _grabDistance) {
              _dragging = TrimHandle.start;
            } else if (toEnd < _grabDistance) {
              _dragging = TrimHandle.end;
            } else {
              _dragging = null;
            }
            dragTo(x);
          },
          onHorizontalDragUpdate: (d) => dragTo(d.localPosition.dx),
          onHorizontalDragEnd: (_) {
            if (_dragging != null) widget.onTrimEnd();
            _dragging = null;
          },
          onTapUp: (d) => widget.onSeek(msOf(d.localPosition.dx).clamp(widget.startMs, widget.endMs)),
          child: SizedBox(
            height: _height,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                // Filmstrip.
                Positioned(
                  left: _handleWidth,
                  right: _handleWidth,
                  top: 4,
                  bottom: 4,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: _Filmstrip(thumbnails: widget.thumbnails),
                  ),
                ),
                // Dim what's trimmed away.
                Positioned(
                  left: _handleWidth,
                  width: startX - _handleWidth,
                  top: 4,
                  bottom: 4,
                  child: const ColoredBox(color: Color(0xA6000000)),
                ),
                Positioned(
                  left: endX,
                  right: _handleWidth,
                  top: 4,
                  bottom: 4,
                  child: const ColoredBox(color: Color(0xA6000000)),
                ),
                // Selection frame with handles.
                Positioned(
                  left: startX - _handleWidth,
                  width: endX - startX + 2 * _handleWidth,
                  top: 0,
                  bottom: 0,
                  child: _SelectionFrame(color: scheme.primary, onColor: scheme.onPrimary),
                ),
                // Playhead.
                Positioned(
                  left: xOf(widget.positionMs.clamp(0, widget.durationMs)) - 1.5,
                  width: 3,
                  top: 0,
                  bottom: 0,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(2),
                      boxShadow: const [BoxShadow(blurRadius: 3, color: Colors.black54)],
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _Filmstrip extends StatelessWidget {
  const _Filmstrip({required this.thumbnails});
  final List<Uint8List>? thumbnails;

  @override
  Widget build(BuildContext context) {
    final thumbs = thumbnails;
    if (thumbs == null || thumbs.isEmpty) {
      return ColoredBox(color: Theme.of(context).colorScheme.surfaceContainerHighest);
    }
    return Row(
      children: [
        for (final t in thumbs)
          Expanded(
            child: Image.memory(t, fit: BoxFit.cover, height: double.infinity, gaplessPlayback: true),
          ),
      ],
    );
  }
}

class _SelectionFrame extends StatelessWidget {
  const _SelectionFrame({required this.color, required this.onColor});
  final Color color;
  final Color onColor;

  @override
  Widget build(BuildContext context) {
    Widget handle(BorderRadius radius) => Container(
      width: _TrimmerState._handleWidth,
      decoration: BoxDecoration(color: color, borderRadius: radius),
      alignment: Alignment.center,
      child: Container(
        width: 3,
        height: 20,
        decoration: BoxDecoration(color: onColor, borderRadius: BorderRadius.circular(2)),
      ),
    );
    const r = Radius.circular(8);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        handle(const BorderRadius.only(topLeft: r, bottomLeft: r)),
        Expanded(
          child: DecoratedBox(
            decoration: BoxDecoration(
              border: Border.symmetric(horizontal: BorderSide(color: color, width: 4)),
            ),
          ),
        ),
        handle(const BorderRadius.only(topRight: r, bottomRight: r)),
      ],
    );
  }
}
