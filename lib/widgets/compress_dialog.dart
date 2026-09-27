import 'dart:async';

import 'package:flutter/material.dart';

import '../engine.dart';
import '../presets.dart';

/// One video to export; [planFor] builds the plan for a given bitrate scale.
class CompressJob {
  const CompressJob(this.source, this.planFor);
  final VideoInfo source;
  final EncodePlan Function(double bitrateScale) planFor;
}

class CompressOutcome {
  const CompressOutcome(this.source, this.output, this.plan);
  final VideoInfo source;
  final VideoInfo output;
  final EncodePlan plan;

  bool get fits => output.sizeBytes <= plan.limitBytes;
}

class CompressFailure {
  const CompressFailure(this.source, this.message);
  final VideoInfo source;
  final String message;
}

class BatchOutcome {
  const BatchOutcome(this.outcomes, this.failures);
  final List<CompressOutcome> outcomes;
  final List<CompressFailure> failures;
}

/// Exports [jobs] one after another and shows progress. Pops with a
/// [BatchOutcome], or null if cancelled (or a single video failed).
///
/// Hardware encoders don't hit a target bitrate exactly, so if a file comes
/// out over the limit we re-encode it with a proportionally lower bitrate.
class CompressDialog extends StatefulWidget {
  const CompressDialog({super.key, required this.jobs});

  final List<CompressJob> jobs;

  @override
  State<CompressDialog> createState() => _CompressDialogState();
}

class _CompressDialogState extends State<CompressDialog> {
  static const _maxPasses = 3;

  StreamSubscription<double>? _progressSub;
  int _index = 0;
  double _progress = 0;
  int _pass = 1;
  String? _error;
  bool _cancelled = false;
  final _stopwatch = Stopwatch()..start();

  int get _count => widget.jobs.length;
  double get _overall => (_index + _progress) / _count;

  @override
  void initState() {
    super.initState();
    _progressSub = Engine.instance.progress.listen((p) {
      if (mounted) setState(() => _progress = p);
    });
    _run();
  }

  @override
  void dispose() {
    _progressSub?.cancel();
    super.dispose();
  }

  Future<void> _run() async {
    final outcomes = <CompressOutcome>[];
    final failures = <CompressFailure>[];
    for (final (i, job) in widget.jobs.indexed) {
      if (_cancelled) break;
      setState(() {
        _index = i;
        _progress = 0;
        _pass = 1;
      });
      // One retry: codec setup can fail transiently when other apps hold the hardware codecs.
      for (var attempt = 1; attempt <= 2; attempt++) {
        try {
          outcomes.add(await _compress(job));
          break;
        } on CompressException catch (e) {
          if (e.cancelled || _cancelled) break;
          if (attempt < 2) {
            if (mounted) {
              setState(() {
                _pass = 1;
                _progress = 0;
              });
            }
            continue;
          }
          if (_count == 1) {
            if (mounted) setState(() => _error = e.toString());
            return;
          }
          failures.add(CompressFailure(job.source, e.toString()));
        }
      }
    }
    if (!mounted) return;
    Navigator.of(context).pop(_cancelled ? null : BatchOutcome(outcomes, failures));
  }

  Future<CompressOutcome> _compress(CompressJob job) async {
    final source = job.source;
    var scale = 1.0;
    while (true) {
      final plan = job.planFor(scale);
      final output = await Engine.instance.compress(
        path: source.path,
        startMs: plan.startMs,
        endMs: plan.endMs >= source.durationMs ? 0 : plan.endMs,
        width: plan.width,
        height: plan.height,
        videoBitrate: plan.videoKbps * 1000,
        audioBitrate: plan.audioKbps * 1000,
        targetFps: plan.fps,
        sourceFps: source.fps ?? 30,
        mute: plan.audioKbps == 0,
      );
      final outcome = CompressOutcome(source, output, plan);
      if (outcome.fits || _pass >= _maxPasses) return outcome;
      scale *= plan.limitBytes / output.sizeBytes * 0.95;
      if (mounted) {
        setState(() {
          _pass++;
          _progress = 0;
        });
      }
    }
  }

  String get _eta {
    final overall = _overall;
    if (overall < 0.03) return 'Starting…';
    final remainingSec = (_stopwatch.elapsedMilliseconds / overall * (1 - overall) / 1000).round();
    return remainingSec < 60 ? 'About ${remainingSec}s left' : 'About ${(remainingSec / 60).ceil()} min left';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (_error != null) {
      return AlertDialog(
        icon: const Icon(Icons.error_outline_rounded),
        title: const Text('Compression failed'),
        content: Text(_error!),
        actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Close'))],
      );
    }
    final title = _count > 1
        ? 'Compressing ${_index + 1} of $_count…'
        : _pass == 1
        ? 'Compressing…'
        : 'Squeezing a bit more…';
    return PopScope(
      canPop: false,
      child: AlertDialog(
        title: Text(title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_pass > 1)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(
                  'The first pass came out slightly over the limit, so this pass uses a lower bitrate.',
                  style: theme.textTheme.bodySmall,
                ),
              ),
            LinearProgressIndicator(
              value: _overall == 0 ? null : _overall,
              borderRadius: BorderRadius.circular(4),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Text('${(_overall * 100).round()}%', style: theme.textTheme.titleMedium),
                const Spacer(),
                Text(_eta, style: theme.textTheme.bodySmall),
              ],
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: _cancelled
                ? null
                : () {
                    setState(() => _cancelled = true);
                    Engine.instance.cancel();
                  },
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
  }
}
