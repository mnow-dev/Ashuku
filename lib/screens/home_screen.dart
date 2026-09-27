import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';

import '../engine.dart';
import '../presets.dart';
import '../thumbnail.dart';
import 'batch_screen.dart';
import 'editor_screen.dart';
import 'library_page.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  final _picker = ImagePicker();
  StreamSubscription<void>? _shareSub;
  MediaAccess? _access;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _shareSub = Engine.instance.incomingShares.listen((_) => _takeIncomingShare());
    Engine.instance.cleanup().then((_) => _takeIncomingShare());
    _checkAccess();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _shareSub?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _checkAccess();
  }

  Future<void> _checkAccess() async {
    var access = await Engine.instance.mediaAccess();
    // Android only tells us "blocked" right after a request; keep it until access changes.
    if (access == MediaAccess.denied && _access == MediaAccess.blocked) access = MediaAccess.blocked;
    if (mounted && access != _access) setState(() => _access = access);
  }

  Future<void> _requestAccess() async {
    if (_access == MediaAccess.blocked) {
      await Engine.instance.openAppSettings();
      return;
    }
    final access = await Engine.instance.requestMediaAccess();
    if (mounted) setState(() => _access = access);
  }

  Future<void> _takeIncomingShare() async {
    setState(() => _loading = true);
    try {
      final path = await Engine.instance.consumeIncomingShare();
      if (path != null) {
        if (!mounted) return;
        Navigator.of(context).popUntil((r) => r.isFirst);
        await _open(path);
      }
    } catch (e) {
      _toast('Couldn\'t import the shared video: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _pick(ImageSource source) async {
    await _busy(() async {
      final file = await _picker.pickVideo(source: source);
      if (file != null) await _open(file.path);
    });
  }

  Future<void> _openLibraryVideo(LibraryVideo video) async {
    await _busy(() async => _open(await Engine.instance.libraryPath(video.id)));
  }

  Future<void> _openMany(List<LibraryVideo> videos) async {
    await _busy(() async {
      final items = <BatchItem>[];
      for (final v in videos) {
        final info = await Engine.instance.probe(await Engine.instance.libraryPath(v.id));
        if (info.hasVideo && info.durationMs > 0) items.add(BatchItem(info, thumbnail: MediaThumbnail(v.id)));
      }
      if (items.isEmpty || !mounted) return;
      setState(() => _loading = false);
      await Navigator.of(context).push(MaterialPageRoute(builder: (_) => BatchScreen(items: items)));
      for (final item in items) {
        await _deleteIfTemporary(item.source.path);
      }
    });
  }

  Future<void> _open(String path) async {
    final info = await Engine.instance.probe(path);
    if (!info.hasVideo || info.durationMs <= 0) {
      _toast('That file doesn\'t contain a playable video.');
      return;
    }
    if (!mounted) return;
    setState(() => _loading = false);
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => EditorScreen(source: info)));
    await _deleteIfTemporary(path);
  }

  /// Picked/shared videos are copied into the cache; drop the copy once we're done.
  /// Library videos opened in place are left alone.
  Future<void> _deleteIfTemporary(String path) async {
    final cache = (await getApplicationCacheDirectory()).path;
    if (!path.startsWith(cache)) return;
    final file = File(path);
    if (await file.exists()) await file.delete();
  }

  Future<void> _busy(Future<void> Function() work) async {
    setState(() => _loading = true);
    try {
      await work();
    } catch (e) {
      _toast('Couldn\'t open the video: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final access = _access;
    final Widget page;
    if (access == null) {
      page = const Scaffold(body: Center(child: CircularProgressIndicator()));
    } else if (access.granted) {
      page = LibraryPage(
        access: access,
        onChangeAccess: _requestAccess,
        onPickWithSystem: () => _pick(ImageSource.gallery),
        onRecord: () => _pick(ImageSource.camera),
        onOpen: _openLibraryVideo,
        onOpenMany: _openMany,
      );
    } else {
      page = _IntroPage(
        blocked: access == MediaAccess.blocked,
        busy: _loading,
        onBrowse: _requestAccess,
        onPick: () => _pick(ImageSource.gallery),
        onRecord: () => _pick(ImageSource.camera),
      );
    }
    final scheme = Theme.of(context).colorScheme;
    return Stack(
      children: [
        page,
        if (_loading)
          Positioned.fill(
            child: ColoredBox(
              color: scheme.surface.withValues(alpha: 0.7),
              child: const Center(child: CircularProgressIndicator()),
            ),
          ),
      ],
    );
  }
}

/// Shown until the app may read the video library.
class _IntroPage extends StatelessWidget {
  const _IntroPage({
    required this.blocked,
    required this.busy,
    required this.onBrowse,
    required this.onPick,
    required this.onRecord,
  });

  final bool blocked;
  final bool busy;
  final VoidCallback onBrowse;
  final VoidCallback onPick;
  final VoidCallback onRecord;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(24, 48, 24, 24),
          children: [
            Center(
              child: Container(
                width: 96,
                height: 96,
                decoration: BoxDecoration(
                  color: scheme.primaryContainer,
                  borderRadius: BorderRadius.circular(28),
                ),
                child: Icon(Icons.compress_rounded, size: 52, color: scheme.onPrimaryContainer),
              ),
            ),
            const SizedBox(height: 24),
            Text('Ashuku', textAlign: TextAlign.center, style: theme.textTheme.displaySmall),
            const SizedBox(height: 8),
            Text(
              'Trim and shrink videos so they fit the chat you\'re sending them to.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyLarge?.copyWith(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 40),
            FilledButton.icon(
              onPressed: busy ? null : onBrowse,
              icon: Icon(blocked ? Icons.settings_rounded : Icons.grid_view_rounded),
              label: Text(blocked ? 'Allow video access in Settings' : 'Browse your videos'),
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(56)),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: busy ? null : onPick,
                    icon: const Icon(Icons.video_library_rounded),
                    label: const Text('Pick one'),
                    style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: busy ? null : onRecord,
                    icon: const Icon(Icons.videocam_rounded),
                    label: const Text('Record'),
                    style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'Browsing lets you preview videos by holding them and send several at once.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 32),
            Text('Presets', style: theme.textTheme.titleSmall?.copyWith(color: scheme.primary)),
            const SizedBox(height: 8),
            for (final p in presets.where((p) => p.id != 'custom'))
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: CircleAvatar(
                  backgroundColor: p.color.withValues(alpha: 0.15),
                  child: Icon(p.icon, color: p.color),
                ),
                title: Text(p.name),
                subtitle: Text(p.summary),
              ),
            const SizedBox(height: 16),
            Text(
              'Tip: in Google Photos, tap Share → Ashuku to jump straight in.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}
