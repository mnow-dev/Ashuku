import 'dart:math';

import 'package:flutter/material.dart';

import '../presets.dart';

/// Two-column grid of target presets.
class PresetGrid extends StatelessWidget {
  const PresetGrid({super.key, required this.selected, required this.onSelect});
  final Preset selected;
  final ValueChanged<Preset> onSelect;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        const gap = 8.0;
        final width = (constraints.maxWidth - gap) / 2;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            for (final p in presets)
              SizedBox(
                width: width,
                child: _PresetCard(preset: p, selected: p == selected, onTap: () => onSelect(p)),
              ),
          ],
        );
      },
    );
  }
}

/// Collapsible size / resolution / frame rate / audio overrides.
class EncodeOptionsPanel extends StatelessWidget {
  const EncodeOptionsPanel({
    super.key,
    required this.options,
    required this.onChanged,
    required this.maxResolution,
    this.showMute = true,
  });

  final EncodeOptions options;
  final ValueChanged<EncodeOptions> onChanged;

  /// Largest short side among the sources; bigger resolutions are disabled.
  final int maxResolution;
  final bool showMute;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final label = theme.textTheme.labelLarge;
    final resolutions = [null, 1080, 720, 540, 480];
    return Card(
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        leading: const Icon(Icons.tune_rounded),
        title: const Text('Adjust'),
        subtitle: Text(
          '${formatMb(options.limitMb)} limit · '
          '${options.resolution == null ? 'auto' : '${options.resolution}p'} · '
          '${options.fps} fps${options.mute ? ' · muted' : ''}',
        ),
        shape: const Border(),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('Size limit', style: label),
              const Spacer(),
              Text(formatMb(options.limitMb), style: theme.textTheme.titleSmall),
            ],
          ),
          Slider(
            value: _mbToSlider(options.limitMb),
            onChanged: (v) => onChanged(options.copyWith(limitMb: _sliderToMb(v))),
          ),
          const SizedBox(height: 8),
          Text('Resolution', style: label),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: SegmentedButton<int?>(
              showSelectedIcon: false,
              segments: [
                for (final r in resolutions)
                  ButtonSegment(
                    value: r,
                    label: Text(r == null ? 'Auto' : '${r}p'),
                    enabled: r == null || r <= maxResolution,
                  ),
              ],
              selected: {options.resolution},
              onSelectionChanged: (s) => onChanged(options.copyWith(resolution: () => s.first)),
            ),
          ),
          const SizedBox(height: 16),
          Text('Frame rate', style: label),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: SegmentedButton<int>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: 24, label: Text('24')),
                ButtonSegment(value: 30, label: Text('30')),
                ButtonSegment(value: 60, label: Text('60')),
              ],
              selected: {options.fps},
              onSelectionChanged: (s) => onChanged(options.copyWith(fps: s.first)),
            ),
          ),
          if (showMute) ...[
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Remove audio'),
              value: options.mute,
              onChanged: (v) => onChanged(options.copyWith(mute: v)),
            ),
          ],
        ],
      ),
    );
  }

  // Log-scale slider from 5 MB to 2 GB, snapped to round numbers.
  static const _minMb = 5.0, _maxMb = 2000.0;
  static double _mbToSlider(double mb) => (log(mb / _minMb) / log(_maxMb / _minMb)).clamp(0, 1);
  static double _sliderToMb(double v) {
    final mb = _minMb * pow(_maxMb / _minMb, v);
    final step = mb < 30
        ? 1
        : mb < 100
        ? 5
        : mb < 500
        ? 25
        : 100;
    return (mb / step).round() * step.toDouble();
  }
}

class _PresetCard extends StatelessWidget {
  const _PresetCard({required this.preset, required this.selected, required this.onTap});
  final Preset preset;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Material(
      color: selected ? scheme.secondaryContainer : scheme.surfaceContainerHigh,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: selected ? scheme.primary : Colors.transparent, width: 2),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              CircleAvatar(
                radius: 18,
                backgroundColor: preset.color.withValues(alpha: 0.18),
                child: Icon(preset.icon, size: 20, color: preset.color),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      preset.name,
                      style: theme.textTheme.titleSmall,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      '≤ ${formatMb(preset.limitMb)} · ${preset.maxShortSide}p',
                      style: theme.textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
