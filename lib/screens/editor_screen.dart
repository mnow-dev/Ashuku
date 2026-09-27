import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../engine.dart';
import '../presets.dart';
import '../widgets/compress_dialog.dart';
import '../widgets/encode_controls.dart';
import '../widgets/trimmer.dart';
import 'result_screen.dart';

class EditorScreen extends StatefulWidget {
  const EditorScreen({super.key, required this.source});
  final VideoInfo source;

  @override
  State<EditorScreen> createState() => _EditorScreenState();
}

class _EditorScreenState extends State<EditorScreen> {
  late final VideoPlayerController _player;
  Timer? _ticker;
  List<Uint8List>? _thumbnails;
  Set<String> _installed = {};

  int _startMs = 0;
  late int _endMs = widget.source.durationMs;
  int _positionMs = 0;
  bool _scrubbing = false;

  Preset _preset = presets.first;
  late EncodeOptions _options = EncodeOptions.of(_preset);

  VideoInfo get _src => widget.source;
  bool get _trimmed => _startMs > 0 || _endMs < _src.durationMs;

  @override
  void initState() {
    super.initState();
    _player = VideoPlayerController.file(File(_src.path))
      ..initialize().then((_) {
        if (mounted) setState(() {});
      });
    _ticker = Timer.periodic(const Duration(milliseconds: 80), (_) => _tick());
    Engine.instance.thumbnails(_src.path, count: 10).then((t) {
      if (mounted) setState(() => _thumbnails = t);
    });
    final packages = {for (final p in presets) ?p.package}.toList();
    Engine.instance.installedPackages(packages).then((s) {
      if (mounted) setState(() => _installed = s);
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _player.dispose();
    super.dispose();
  }

  /// Tracks the playhead and loops playback inside the trim range.
  Future<void> _tick() async {
    if (!_player.value.isInitialized || _scrubbing) return;
    var pos = (await _player.position)?.inMilliseconds ?? 0;
    if (!mounted) return;
    if (_player.value.isPlaying && (pos >= _endMs || pos < _startMs - 250)) {
      pos = _startMs;
      await _player.seekTo(Duration(milliseconds: pos));
    }
    if (pos != _positionMs) setState(() => _positionMs = pos);
  }

  void _seek(int ms) {
    setState(() => _positionMs = ms);
    _player.seekTo(Duration(milliseconds: ms));
  }

  Future<void> _togglePlay() async {
    if (_player.value.isPlaying) {
      await _player.pause();
    } else {
      if (_positionMs >= _endMs - 100 || _positionMs < _startMs) _seek(_startMs);
      await _player.play();
    }
    setState(() {});
  }

  void _onTrim(int start, int end, TrimHandle moved) {
    _scrubbing = true;
    if (_player.value.isPlaying) _player.pause();
    setState(() {
      _startMs = start;
      _endMs = end;
    });
    _seek(moved == TrimHandle.start ? start : end);
  }

  void _onTrimEnd() {
    _scrubbing = false;
    _seek(_startMs);
  }

  void _setStartHere() {
    if (_positionMs >= _endMs - 300) return;
    setState(() => _startMs = _positionMs);
  }

  void _setEndHere() {
    if (_positionMs <= _startMs + 300) return;
    setState(() => _endMs = _positionMs);
  }

  void _fitDuration(int seconds) {
    setState(() => _endMs = min(_src.durationMs, _startMs + seconds * 1000));
    _seek(_startMs);
  }

  void _selectPreset(Preset p) {
    setState(() {
      _preset = p;
      _options = EncodeOptions.of(p);
    });
  }

  EncodePlan _plan([double bitrateScale = 1]) => makePlan(
    source: _src,
    preset: _preset,
    options: _options,
    startMs: _startMs,
    endMs: _endMs,
    bitrateScale: bitrateScale,
  );

  Future<void> _compress() async {
    await _player.pause();
    if (!mounted) return;
    final batch = await showDialog<BatchOutcome>(
      context: context,
      barrierDismissible: false,
      builder: (_) => CompressDialog(jobs: [CompressJob(_src, _plan)]),
    );
    if (batch == null || batch.outcomes.isEmpty || !mounted) return;
    final outcome = batch.outcomes.first;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ResultScreen(
          source: _src,
          output: outcome.output,
          plan: outcome.plan,
          preset: _preset,
          canSendDirectly: _preset.package != null && _installed.contains(_preset.package),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final plan = _plan();
    return Scaffold(
      appBar: AppBar(title: const Text('Edit')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
        children: [
          _buildPreview(context),
          const SizedBox(height: 16),
          // Extra inset keeps the handles clear of the system back-gesture edges.
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Trimmer(
              durationMs: _src.durationMs,
              startMs: _startMs,
              endMs: _endMs,
              positionMs: _positionMs,
              thumbnails: _thumbnails,
              onTrim: _onTrim,
              onTrimEnd: _onTrimEnd,
              onSeek: _seek,
            ),
          ),
          const SizedBox(height: 4),
          _buildTrimBar(context),
          const SizedBox(height: 20),
          Text('Send to', style: theme.textTheme.titleSmall?.copyWith(color: theme.colorScheme.primary)),
          const SizedBox(height: 8),
          PresetGrid(selected: _preset, onSelect: _selectPreset),
          const SizedBox(height: 8),
          Text(
            _preset.notes,
            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 16),
          for (final w in plan.warnings) ...[
            _WarningCard(warning: w, onFit: _fitDuration),
            const SizedBox(height: 8),
          ],
          _SummaryCard(source: _src, plan: plan),
          const SizedBox(height: 12),
          EncodeOptionsPanel(
            options: _options,
            maxResolution: _src.shortSide,
            showMute: _src.hasAudio,
            onChanged: (o) => setState(() => _options = o),
          ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: FilledButton.icon(
            onPressed: _compress,
            icon: const Icon(Icons.compress_rounded),
            label: Text('Compress  ·  ≈ ${formatBytes(plan.estimatedBytes)}'),
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(56)),
          ),
        ),
      ),
    );
  }

  Widget _buildPreview(BuildContext context) {
    final value = _player.value;
    final aspect = value.isInitialized ? value.aspectRatio : _src.aspectRatio;
    final maxHeight = MediaQuery.sizeOf(context).height * 0.42;
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: AspectRatio(
          aspectRatio: aspect,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: GestureDetector(
              onTap: _togglePlay,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  const ColoredBox(color: Colors.black),
                  if (value.isInitialized) VideoPlayer(_player),
                  AnimatedOpacity(
                    opacity: value.isPlaying ? 0 : 1,
                    duration: const Duration(milliseconds: 150),
                    child: const Center(
                      child: CircleAvatar(
                        radius: 30,
                        backgroundColor: Colors.black45,
                        child: Icon(Icons.play_arrow_rounded, size: 40, color: Colors.white),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTrimBar(BuildContext context) {
    final theme = Theme.of(context);
    final small = theme.textTheme.labelMedium;
    return Row(
      children: [
        IconButton(
          tooltip: 'Start at playhead',
          onPressed: _setStartHere,
          icon: const Icon(Icons.first_page_rounded),
        ),
        Text(formatDuration(_startMs), style: small),
        Expanded(
          child: Column(
            children: [
              Text(formatDuration(_endMs - _startMs), style: theme.textTheme.titleSmall),
              Text(
                _trimmed ? 'of ${formatDuration(_src.durationMs)}' : 'full clip',
                style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
        Text(formatDuration(_endMs), style: small),
        IconButton(
          tooltip: 'End at playhead',
          onPressed: _setEndHere,
          icon: const Icon(Icons.last_page_rounded),
        ),
      ],
    );
  }
}

class _WarningCard extends StatelessWidget {
  const _WarningCard({required this.warning, required this.onFit});
  final PlanWarning warning;
  final ValueChanged<int> onFit;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fit = warning.fitDurationSec;
    return Card(
      color: fit != null ? scheme.errorContainer : scheme.tertiaryContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
        child: Row(
          children: [
            Icon(
              fit != null ? Icons.timer_outlined : Icons.info_outline_rounded,
              color: fit != null ? scheme.onErrorContainer : scheme.onTertiaryContainer,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                warning.text,
                style: TextStyle(color: fit != null ? scheme.onErrorContainer : scheme.onTertiaryContainer),
              ),
            ),
            if (fit != null) TextButton(onPressed: () => onFit(fit), child: Text('Trim to ${fit}s')),
          ],
        ),
      ),
    );
  }
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({required this.source, required this.plan});
  final VideoInfo source;
  final EncodePlan plan;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final strong = theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600);
    final srcBitrate = source.bitrate;
    TableRow row(String label, String from, String to) => TableRow(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Text(label, style: muted),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Text(from, style: muted),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Text(to, style: strong),
        ),
      ],
    );
    final fits = plan.estimatedBytes <= plan.limitBytes;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Table(
              columnWidths: const {0: FlexColumnWidth(1.1), 1: FlexColumnWidth(1.3), 2: FlexColumnWidth(1.3)},
              children: [
                TableRow(
                  children: [
                    const SizedBox(),
                    Text('Original', style: theme.textTheme.labelLarge),
                    Text('Output', style: theme.textTheme.labelLarge),
                  ],
                ),
                row('Size', formatBytes(source.sizeBytes), '≈ ${formatBytes(plan.estimatedBytes)}'),
                row('Resolution', '${source.width}×${source.height}', '${plan.width}×${plan.height}'),
                row(
                  'Frame rate',
                  source.fps == null ? '—' : '${source.fps!.round()} fps',
                  '${plan.fps.round()} fps',
                ),
                row('Length', formatDuration(source.durationMs), formatDuration(plan.durationMs)),
                row(
                  'Bitrate',
                  srcBitrate == null ? '—' : formatKbps(srcBitrate / 1000),
                  formatKbps(plan.videoKbps + plan.audioKbps),
                ),
              ],
            ),
            if (!fits) ...[
              const SizedBox(height: 8),
              Text('Estimate is over the limit; the encoder will try harder.', style: muted),
            ],
          ],
        ),
      ),
    );
  }
}
