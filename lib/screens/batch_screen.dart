import 'dart:math';

import 'package:flutter/material.dart';

import '../engine.dart';
import '../presets.dart';
import '../thumbnail.dart';
import '../widgets/compress_dialog.dart';
import '../widgets/encode_controls.dart';
import '../widgets/hold_preview.dart';
import 'batch_result_screen.dart';

class BatchItem {
  const BatchItem(this.source, {this.thumbnail});
  final VideoInfo source;
  final ImageProvider? thumbnail;
}

/// Compresses several videos with one preset.
class BatchScreen extends StatefulWidget {
  const BatchScreen({super.key, required this.items});
  final List<BatchItem> items;

  @override
  State<BatchScreen> createState() => _BatchScreenState();
}

class _BatchScreenState extends State<BatchScreen> {
  late final List<BatchItem> _items = [...widget.items];
  Preset _preset = presets.first;
  late EncodeOptions _options = EncodeOptions.of(_preset);

  /// Cut clips that are longer than the preset allows down to their start.
  bool _fitDuration = true;
  Set<String> _installed = {};

  @override
  void initState() {
    super.initState();
    final packages = {for (final p in presets) ?p.package}.toList();
    Engine.instance.installedPackages(packages).then((s) {
      if (mounted) setState(() => _installed = s);
    });
  }

  EncodePlan _planFor(VideoInfo source, [double bitrateScale = 1]) {
    final maxSec = _preset.maxDurationSec;
    final endMs = maxSec != null && _fitDuration ? min(source.durationMs, maxSec * 1000) : source.durationMs;
    return makePlan(
      source: source,
      preset: _preset,
      options: _options,
      startMs: 0,
      endMs: endMs,
      bitrateScale: bitrateScale,
    );
  }

  void _remove(BatchItem item) {
    setState(() => _items.remove(item));
    if (_items.isEmpty) Navigator.of(context).pop();
  }

  Future<void> _compress() async {
    final outcome = await showDialog<BatchOutcome>(
      context: context,
      barrierDismissible: false,
      builder: (_) => CompressDialog(
        jobs: [for (final item in _items) CompressJob(item.source, (s) => _planFor(item.source, s))],
      ),
    );
    if (outcome == null || !mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => BatchResultScreen(
          outcome: outcome,
          preset: _preset,
          canSendDirectly: _preset.package != null && _installed.contains(_preset.package),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final plans = {for (final item in _items) item: _planFor(item.source)};
    final total = plans.values.fold(0, (sum, p) => sum + p.estimatedBytes);
    final maxSec = _preset.maxDurationSec;
    final tooLong = maxSec == null ? 0 : _items.where((i) => i.source.durationMs > maxSec * 1000 + 50).length;
    final anyHdr = _items.any((i) => i.source.isHdr);
    final lowBitrate = plans.values.any((p) => p.videoKbps < 400);

    return Scaffold(
      appBar: AppBar(title: Text('${_items.length} videos')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
        children: [
          Text('Hold a video to preview it.', style: muted),
          const SizedBox(height: 8),
          Card(
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                for (final item in _items)
                  _BatchTile(item: item, plan: plans[item]!, onRemove: () => _remove(item)),
              ],
            ),
          ),
          const SizedBox(height: 20),
          Text('Send to', style: theme.textTheme.titleSmall?.copyWith(color: theme.colorScheme.primary)),
          const SizedBox(height: 8),
          PresetGrid(
            selected: _preset,
            onSelect: (p) => setState(() {
              _preset = p;
              _options = EncodeOptions.of(p);
            }),
          ),
          const SizedBox(height: 8),
          Text(_preset.notes, style: muted),
          const SizedBox(height: 16),
          if (tooLong > 0) ...[
            Card(
              color: _fitDuration ? theme.colorScheme.secondaryContainer : theme.colorScheme.errorContainer,
              child: SwitchListTile(
                secondary: const Icon(Icons.timer_outlined),
                title: Text('Cut to the first ${maxSec}s'),
                subtitle: Text(
                  '$tooLong ${tooLong == 1 ? 'clip is' : 'clips are'} longer than ${_preset.name} allows.',
                ),
                value: _fitDuration,
                onChanged: (v) => setState(() => _fitDuration = v),
              ),
            ),
            const SizedBox(height: 8),
          ],
          if (lowBitrate) ...[
            const _Note(
              icon: Icons.info_outline_rounded,
              text: 'Some clips get a very low bitrate. Trim them first or raise the size limit.',
            ),
            const SizedBox(height: 8),
          ],
          if (anyHdr) ...[
            const _Note(
              icon: Icons.info_outline_rounded,
              text: 'HDR videos will be converted to SDR so they play correctly in chats.',
            ),
            const SizedBox(height: 8),
          ],
          EncodeOptionsPanel(
            options: _options,
            maxResolution: _items.map((i) => i.source.shortSide).reduce(max),
            showMute: _items.any((i) => i.source.hasAudio),
            onChanged: (o) => setState(() => _options = o),
          ),
          const SizedBox(height: 8),
          Text('The size limit applies to each video separately.', style: muted, textAlign: TextAlign.center),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: FilledButton.icon(
            onPressed: _compress,
            icon: const Icon(Icons.compress_rounded),
            label: Text('Compress ${_items.length}  ·  ≈ ${formatBytes(total)}'),
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(56)),
          ),
        ),
      ),
    );
  }
}

class _BatchTile extends StatelessWidget {
  const _BatchTile({required this.item, required this.plan, required this.onRemove});
  final BatchItem item;
  final EncodePlan plan;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final src = item.source;
    final thumbnail = item.thumbnail ?? FileVideoThumbnail(src.path);
    final trimmed = plan.durationMs < src.durationMs - 50;
    return HoldToPreview(
      source: PreviewSource(
        path: src.path,
        placeholder: thumbnail,
        aspectRatio: src.aspectRatio,
        caption: '${formatDuration(src.durationMs, tenths: false)} · ${formatBytes(src.sizeBytes)}',
      ),
      child: ListTile(
        leading: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Image(image: thumbnail, width: 52, height: 52, fit: BoxFit.cover),
        ),
        title: Text('${formatBytes(src.sizeBytes)} → ≈ ${formatBytes(plan.estimatedBytes)}'),
        subtitle: Text(
          '${formatDuration(plan.durationMs, tenths: false)}${trimmed ? ' (cut)' : ''} · '
          '${plan.width}×${plan.height}',
        ),
        trailing: IconButton(tooltip: 'Remove', icon: const Icon(Icons.close_rounded), onPressed: onRemove),
      ),
    );
  }
}

class _Note extends StatelessWidget {
  const _Note({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: scheme.tertiaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(icon, color: scheme.onTertiaryContainer),
            const SizedBox(width: 12),
            Expanded(
              child: Text(text, style: TextStyle(color: scheme.onTertiaryContainer)),
            ),
          ],
        ),
      ),
    );
  }
}
