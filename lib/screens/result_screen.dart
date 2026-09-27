import 'dart:io';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../engine.dart';
import '../presets.dart';

class ResultScreen extends StatefulWidget {
  const ResultScreen({
    super.key,
    required this.source,
    required this.output,
    required this.plan,
    required this.preset,
    required this.canSendDirectly,
  });

  final VideoInfo source;
  final VideoInfo output;
  final EncodePlan plan;
  final Preset preset;
  final bool canSendDirectly;

  @override
  State<ResultScreen> createState() => _ResultScreenState();
}

class _ResultScreenState extends State<ResultScreen> {
  late final VideoPlayerController _player;
  bool _saving = false;
  bool _saved = false;

  VideoInfo get _out => widget.output;

  @override
  void initState() {
    super.initState();
    _player = VideoPlayerController.file(File(_out.path))
      ..setLooping(true)
      ..initialize().then((_) {
        if (mounted) setState(() {});
      })
      ..addListener(_onPlayer);
  }

  void _onPlayer() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _player
      ..removeListener(_onPlayer)
      ..dispose();
    super.dispose();
  }

  Future<void> _share({Preset? to}) async {
    await _player.pause();
    await Engine.instance.share([_out.path], package: to?.package, activity: to?.shareActivity);
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await Engine.instance.saveToGallery(_out.path);
      if (mounted) setState(() => _saved = true);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Couldn\'t save: $e')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final value = _player.value;
    final limit = widget.plan.limitBytes;
    final fits = _out.sizeBytes <= limit;
    final saved = 1 - _out.sizeBytes / widget.source.sizeBytes;
    final preset = widget.preset;

    return Scaffold(
      appBar: AppBar(title: const Text('Ready to send')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
        children: [
          Center(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.42),
              child: AspectRatio(
                aspectRatio: value.isInitialized ? value.aspectRatio : _out.aspectRatio,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: GestureDetector(
                    onTap: () => value.isPlaying ? _player.pause() : _player.play(),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        const ColoredBox(color: Colors.black),
                        if (value.isInitialized) VideoPlayer(_player),
                        if (!value.isPlaying)
                          const Center(
                            child: CircleAvatar(
                              radius: 30,
                              backgroundColor: Colors.black45,
                              child: Icon(Icons.play_arrow_rounded, size: 40, color: Colors.white),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 24),
          Text(formatBytes(_out.sizeBytes), textAlign: TextAlign.center, style: theme.textTheme.displaySmall),
          const SizedBox(height: 4),
          Text(
            saved > 0
                ? 'from ${formatBytes(widget.source.sizeBytes)} · ${(saved * 100).round()}% smaller'
                : 'from ${formatBytes(widget.source.sizeBytes)}',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 12),
          Center(
            child: Chip(
              avatar: Icon(
                fits ? Icons.check_circle_rounded : Icons.warning_amber_rounded,
                color: fits ? Colors.green : scheme.error,
              ),
              label: Text(
                fits
                    ? 'Fits ${preset.name} (≤ ${formatMb(limit / 1e6)})'
                    : '${formatBytes(_out.sizeBytes - limit)} over the ${formatMb(limit / 1e6)} limit',
              ),
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 8,
            runSpacing: 8,
            children: [
              _Stat(Icons.aspect_ratio_rounded, '${_out.width}×${_out.height}'),
              if (_out.fps != null) _Stat(Icons.speed_rounded, '${_out.fps!.round()} fps'),
              _Stat(Icons.timer_outlined, formatDuration(_out.durationMs)),
              if (_out.bitrate != null) _Stat(Icons.graphic_eq_rounded, formatKbps(_out.bitrate! / 1000)),
            ],
          ),
          const SizedBox(height: 28),
          if (widget.canSendDirectly) ...[
            FilledButton.icon(
              onPressed: () => _share(to: preset),
              icon: Icon(preset.icon),
              label: Text('Send via ${preset.appName}'),
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(56)),
            ),
            const SizedBox(height: 12),
          ],
          Row(
            children: [
              Expanded(
                child: widget.canSendDirectly
                    ? OutlinedButton.icon(
                        onPressed: _share,
                        icon: const Icon(Icons.share_rounded),
                        label: const Text('Share…'),
                        style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                      )
                    : FilledButton.tonalIcon(
                        onPressed: _share,
                        icon: const Icon(Icons.share_rounded),
                        label: const Text('Share…'),
                        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                      ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _saving || _saved ? null : _save,
                  icon: Icon(_saved ? Icons.check_rounded : Icons.download_rounded),
                  label: Text(_saved ? 'Saved' : 'Save'),
                  style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                ),
              ),
            ],
          ),
          if (_saved)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'Saved to Movies/Ashuku',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ),
        ],
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat(this.icon, this.text);
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) =>
      Chip(avatar: Icon(icon, size: 18), label: Text(text), visualDensity: VisualDensity.compact);
}
