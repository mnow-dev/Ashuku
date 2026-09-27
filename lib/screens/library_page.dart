import 'package:flutter/material.dart';

import '../engine.dart';
import '../presets.dart';
import '../thumbnail.dart';
import '../widgets/hold_preview.dart';

/// Grid of the device's videos: tap to edit, hold to preview, select several to batch.
class LibraryPage extends StatefulWidget {
  const LibraryPage({
    super.key,
    required this.access,
    required this.onChangeAccess,
    required this.onPickWithSystem,
    required this.onRecord,
    required this.onOpen,
    required this.onOpenMany,
  });

  final MediaAccess access;
  final VoidCallback onChangeAccess;
  final VoidCallback onPickWithSystem;
  final VoidCallback onRecord;
  final ValueChanged<LibraryVideo> onOpen;
  final ValueChanged<List<LibraryVideo>> onOpenMany;

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> with WidgetsBindingObserver {
  List<Album>? _albums;

  /// Selected album, or null for all videos.
  int? _albumId;
  List<LibraryVideo>? _videos;
  int _loadToken = 0;

  /// In the order they were picked, which is the order they're sent in.
  final _selected = <LibraryVideo>[];
  bool get _selecting => _selected.isNotEmpty;

  /// The tap that dismisses the permission dialog can land on the freshly shown
  /// grid and open a random video, so ignore the grid briefly after it appears.
  bool _settled = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load(initial: true);
    Future.delayed(const Duration(milliseconds: 700), () {
      if (mounted) setState(() => _settled = true);
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Pick up new recordings and permission changes made outside the app.
    if (state == AppLifecycleState.resumed) _load();
  }

  @override
  void didUpdateWidget(LibraryPage old) {
    super.didUpdateWidget(old);
    if (old.access != widget.access) _load();
  }

  Future<void> _load({bool initial = false}) async {
    final token = ++_loadToken;
    final albums = await Engine.instance.albums();
    if (initial) {
      _albumId = albums.where((a) => a.isCamera).firstOrNull?.id;
    } else if (_albumId != null && !albums.any((a) => a.id == _albumId)) {
      _albumId = null;
    }
    final videos = await Engine.instance.videos(album: _albumId);
    if (!mounted || token != _loadToken) return;
    setState(() {
      _albums = albums;
      _videos = videos;
    });
  }

  void _selectAlbum(int? id) {
    if (id == _albumId) return;
    setState(() {
      _albumId = id;
      _videos = null;
    });
    _load();
  }

  void _toggle(LibraryVideo v) {
    setState(() => _selected.contains(v) ? _selected.remove(v) : _selected.add(v));
  }

  void _openSelection() {
    final picked = [..._selected];
    if (picked.length == 1) {
      widget.onOpen(picked.first);
    } else {
      widget.onOpenMany(picked);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PopScope(
      canPop: !_selecting,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) setState(_selected.clear);
      },
      child: Scaffold(
        appBar: _selecting
            ? AppBar(
                leading: IconButton(
                  tooltip: 'Clear selection',
                  icon: const Icon(Icons.close_rounded),
                  onPressed: () => setState(_selected.clear),
                ),
                title: Text('${_selected.length} selected'),
              )
            : AppBar(
                title: const Text('Ashuku'),
                actions: [
                  IconButton(
                    tooltip: 'Pick with system picker',
                    icon: const Icon(Icons.photo_library_outlined),
                    onPressed: widget.onPickWithSystem,
                  ),
                  IconButton(
                    tooltip: 'Record a video',
                    icon: const Icon(Icons.videocam_outlined),
                    onPressed: widget.onRecord,
                  ),
                ],
              ),
        body: Column(
          children: [
            _buildAlbumChips(),
            if (widget.access == MediaAccess.partial) _PartialAccessBanner(onChange: widget.onChangeAccess),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 2, 16, 8),
              child: Text(
                'Tap to edit · hold to preview, slide to scrub · ○ to pick several',
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
            Expanded(
              child: AbsorbPointer(
                absorbing: !_settled,
                child: RefreshIndicator(onRefresh: _load, child: _buildGrid()),
              ),
            ),
          ],
        ),
        bottomNavigationBar: _selecting
            ? SafeArea(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                  child: FilledButton.icon(
                    onPressed: _openSelection,
                    icon: Icon(_selected.length == 1 ? Icons.content_cut_rounded : Icons.compress_rounded),
                    label: Text(
                      _selected.length == 1 ? 'Edit & trim' : 'Compress ${_selected.length} videos',
                    ),
                    style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(56)),
                  ),
                ),
              )
            : null,
      ),
    );
  }

  Widget _buildAlbumChips() {
    final albums = _albums ?? [];
    final camera = albums.where((a) => a.isCamera);
    final others = albums.where((a) => !a.isCamera);
    final total = albums.fold(0, (s, a) => s + a.count);
    Widget chip(String label, int? id) => Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Builder(
        builder: (context) => ChoiceChip(
          label: Text(label),
          selected: _albumId == id,
          onSelected: (_) {
            _selectAlbum(id);
            Scrollable.ensureVisible(context, alignment: 0.5, duration: const Duration(milliseconds: 200));
          },
        ),
      ),
    );
    return SizedBox(
      height: 48,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        children: [
          for (final a in camera) chip('Camera · ${a.count}', a.id),
          chip('All videos · $total', null),
          for (final a in others) chip('${a.name} · ${a.count}', a.id),
        ],
      ),
    );
  }

  Widget _buildGrid() {
    final videos = _videos;
    if (videos == null) return const Center(child: CircularProgressIndicator());
    if (videos.isEmpty) {
      return ListView(
        children: const [
          SizedBox(height: 120),
          Icon(Icons.videocam_off_outlined, size: 48),
          SizedBox(height: 12),
          Center(child: Text('No videos here yet')),
        ],
      );
    }
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(2, 0, 2, 16),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        mainAxisSpacing: 2,
        crossAxisSpacing: 2,
      ),
      itemCount: videos.length,
      itemBuilder: (context, i) {
        final v = videos[i];
        final index = _selected.indexOf(v);
        return _VideoCell(
          video: v,
          selectedIndex: index >= 0 ? index + 1 : null,
          onTap: () => _selecting ? _toggle(v) : widget.onOpen(v),
          onToggle: () => _toggle(v),
        );
      },
    );
  }
}

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

class _VideoCell extends StatelessWidget {
  const _VideoCell({
    required this.video,
    required this.selectedIndex,
    required this.onTap,
    required this.onToggle,
  });

  final LibraryVideo video;

  /// 1-based position in the selection, or null.
  final int? selectedIndex;
  final VoidCallback onTap;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final thumbnail = MediaThumbnail(video.id);
    final selected = selectedIndex != null;
    final d = video.dateTaken;
    return HoldToPreview(
      source: PreviewSource(
        uri: video.uri,
        placeholder: thumbnail,
        aspectRatio: video.aspectRatio,
        caption:
            '${formatDuration(video.durationMs, tenths: false)} · ${formatBytes(video.sizeBytes)} · '
            '${d.day} ${_months[d.month - 1]} ${d.year}',
      ),
      onTap: onTap,
      child: ColoredBox(
        color: selected ? scheme.primaryContainer : scheme.surfaceContainerHighest,
        child: Stack(
          fit: StackFit.expand,
          children: [
            AnimatedPadding(
              duration: const Duration(milliseconds: 120),
              padding: EdgeInsets.all(selected ? 10 : 0),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(selected ? 10 : 0),
                child: Image(
                  image: thumbnail,
                  fit: BoxFit.cover,
                  gaplessPlayback: true,
                  errorBuilder: (_, _, _) => const Center(child: Icon(Icons.broken_image_outlined)),
                ),
              ),
            ),
            Positioned(
              right: 6,
              bottom: 6,
              child: DecoratedBox(
                decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(4)),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                  child: Text(
                    formatDuration(video.durationMs, tenths: false),
                    style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w600),
                  ),
                ),
              ),
            ),
            // Selection toggle; a generous hit area in the corner.
            Positioned(
              top: 0,
              right: 0,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: onToggle,
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: _SelectBadge(index: selectedIndex),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SelectBadge extends StatelessWidget {
  const _SelectBadge({required this.index});
  final int? index;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final selected = index != null;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      width: 24,
      height: 24,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: selected ? scheme.primary : Colors.black26,
        border: Border.all(color: Colors.white, width: 2),
      ),
      alignment: Alignment.center,
      child: selected
          ? Text(
              '$index',
              style: TextStyle(color: scheme.onPrimary, fontSize: 12, fontWeight: FontWeight.w700),
            )
          : null,
    );
  }
}

class _PartialAccessBanner extends StatelessWidget {
  const _PartialAccessBanner({required this.onChange});
  final VoidCallback onChange;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Material(
        color: scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 4, 4),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'Showing only the videos you allowed.',
                  style: TextStyle(color: scheme.onSecondaryContainer),
                ),
              ),
              TextButton(onPressed: onChange, child: const Text('Change')),
            ],
          ),
        ),
      ),
    );
  }
}
