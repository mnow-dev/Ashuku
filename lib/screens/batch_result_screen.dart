import 'package:flutter/material.dart';

import '../engine.dart';
import '../presets.dart';
import '../thumbnail.dart';
import '../widgets/compress_dialog.dart';
import '../widgets/hold_preview.dart';

class BatchResultScreen extends StatefulWidget {
  const BatchResultScreen({
    super.key,
    required this.outcome,
    required this.preset,
    required this.canSendDirectly,
  });

  final BatchOutcome outcome;
  final Preset preset;
  final bool canSendDirectly;

  @override
  State<BatchResultScreen> createState() => _BatchResultScreenState();
}

class _BatchResultScreenState extends State<BatchResultScreen> {
  /// Whether the target takes all videos in one share; null while checking.
  bool? _sendsAll;
  final _sent = <String>{};
  bool _saving = false;
  bool _saved = false;

  List<CompressOutcome> get _outcomes => widget.outcome.outcomes;
  List<String> get _paths => [for (final o in _outcomes) o.output.path];

  @override
  void initState() {
    super.initState();
    final p = widget.preset;
    if (widget.canSendDirectly && _outcomes.length > 1) {
      Engine.instance.canSendMultiple(p.package!, activity: p.shareActivity).then((v) {
        if (mounted) setState(() => _sendsAll = v);
      });
    } else {
      _sendsAll = true;
    }
  }

  Future<void> _sendOne(CompressOutcome o) async {
    await Engine.instance.share(
      [o.output.path],
      package: widget.preset.package,
      activity: widget.preset.shareActivity,
    );
    setState(() => _sent.add(o.output.path));
  }

  Future<void> _saveAll() async {
    setState(() => _saving = true);
    try {
      for (final path in _paths) {
        await Engine.instance.saveToGallery(path);
      }
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
    final preset = widget.preset;
    final totalOut = _outcomes.fold(0, (s, o) => s + o.output.sizeBytes);
    final totalIn = _outcomes.fold(0, (s, o) => s + o.source.sizeBytes);
    final over = _outcomes.where((o) => !o.fits).length;
    final oneByOne = widget.canSendDirectly && _sendsAll == false;
    final limit = _outcomes.isEmpty ? 0 : _outcomes.first.plan.limitBytes;

    return Scaffold(
      appBar: AppBar(title: const Text('Ready to send')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          Text(
            '${_outcomes.length} ${_outcomes.length == 1 ? 'video' : 'videos'} · ${formatBytes(totalOut)}',
            textAlign: TextAlign.center,
            style: theme.textTheme.headlineMedium,
          ),
          const SizedBox(height: 4),
          if (totalIn > 0)
            Text(
              'from ${formatBytes(totalIn)} · ${((1 - totalOut / totalIn) * 100).round()}% smaller',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
            ),
          const SizedBox(height: 12),
          Center(
            child: Chip(
              avatar: Icon(
                over == 0 ? Icons.check_circle_rounded : Icons.warning_amber_rounded,
                color: over == 0 ? Colors.green : scheme.error,
              ),
              label: Text(
                over == 0
                    ? '${_outcomes.length == 1 ? 'Fits' : 'Each fits'} ${preset.name} (≤ ${formatMb(limit / 1e6)})'
                    : '$over over the ${formatMb(limit / 1e6)} limit',
              ),
            ),
          ),
          const SizedBox(height: 16),
          Card(
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                for (final o in _outcomes)
                  _OutputTile(
                    outcome: o,
                    sendIcon: oneByOne ? preset.icon : null,
                    sent: _sent.contains(o.output.path),
                    onSend: () => _sendOne(o),
                  ),
                for (final f in widget.outcome.failures)
                  ListTile(
                    leading: Icon(Icons.error_outline_rounded, color: scheme.error),
                    title: Text('${f.source.name} failed'),
                    subtitle: Text(f.message, maxLines: 2, overflow: TextOverflow.ellipsis),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Text(
            oneByOne
                ? '${preset.appName} takes one video at a time here. Tap send on each one.'
                : 'Hold a video to preview it.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 20),
          if (widget.canSendDirectly && _sendsAll == true) ...[
            FilledButton.icon(
              onPressed: () =>
                  Engine.instance.share(_paths, package: preset.package, activity: preset.shareActivity),
              icon: Icon(preset.icon),
              label: Text(
                _outcomes.length == 1 ? 'Send via ${preset.appName}' : 'Send all via ${preset.appName}',
              ),
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(56)),
            ),
            const SizedBox(height: 12),
          ],
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => Engine.instance.share(_paths),
                  icon: const Icon(Icons.share_rounded),
                  label: const Text('Share all…'),
                  style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _saving || _saved ? null : _saveAll,
                  icon: Icon(_saved ? Icons.check_rounded : Icons.download_rounded),
                  label: Text(_saved ? 'Saved' : 'Save all'),
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

class _OutputTile extends StatelessWidget {
  const _OutputTile({
    required this.outcome,
    required this.sendIcon,
    required this.sent,
    required this.onSend,
  });
  final CompressOutcome outcome;

  /// Shown as a per-video send button when the target app takes one at a time.
  final IconData? sendIcon;
  final bool sent;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    final out = outcome.output;
    final scheme = Theme.of(context).colorScheme;
    final thumbnail = FileVideoThumbnail(out.path);
    return HoldToPreview(
      source: PreviewSource(
        path: out.path,
        placeholder: thumbnail,
        aspectRatio: out.aspectRatio,
        durationMs: out.durationMs,
        caption: '${formatBytes(out.sizeBytes)} · ${out.width}×${out.height}',
      ),
      child: ListTile(
        leading: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Image(image: thumbnail, width: 52, height: 52, fit: BoxFit.cover),
        ),
        title: Text(formatBytes(out.sizeBytes)),
        subtitle: Text('${formatDuration(out.durationMs, tenths: false)} · ${out.width}×${out.height}'),
        trailing: sendIcon != null
            ? IconButton.filledTonal(
                tooltip: 'Send',
                onPressed: onSend,
                icon: Icon(sent ? Icons.check_rounded : sendIcon),
              )
            : Icon(
                outcome.fits ? Icons.check_circle_rounded : Icons.warning_amber_rounded,
                color: outcome.fits ? Colors.green : scheme.error,
              ),
      ),
    );
  }
}
