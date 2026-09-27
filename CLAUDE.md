# Ashuku: notes for Claude

Ashuku is a Flutter Android app that trims and compresses videos to fit chat apps' size limits (Messenger, Google Chat, Instagram). The UI is Dart. The video work is native Kotlin on Media3 Transformer, behind one method channel. Android only (minSdk 29), arm64 releases.

## Commands

```sh
flutter test                      # planner unit tests (test/planner_test.dart)
flutter analyze
dart format -l 110 lib test       # this repo uses 110-column lines
flutter build apk --release --target-platform android-arm64
adb -s <serial> install -r build/app/outputs/flutter-apk/app-release.apk
```

Several devices and emulators are often connected, so always pass `adb -s`.

## Architecture

- **Dart → native:** everything goes through `lib/engine.dart` (`Engine.instance`) on the `ashuku/video` MethodChannel. When you add a method, add it in both `Engine` and `MainActivity.handle`. Native calls Dart back for `progress` and `incomingShare`.
- **`android/.../VideoEngine.kt`:** probe (MediaMetadataRetriever and MediaExtractor), filmstrip thumbnails, Media3 export, saving to MediaStore, importing shared URIs.
  - Transformer has to be created and used on the main thread; progress is polled with a Handler.
  - `cancel()` doesn't fire Transformer listeners, so the pending result is settled by hand.
- **`android/.../MediaLibrary.kt`:** MediaStore albums, video lists and thumbnails for the in-app browser. It opens files by real path when readable and copies into the cache otherwise.
- **`android/.../MainActivity.kt`:**
  - media permissions, including Android 14+ partial access
  - share in (ACTION_SEND) and share out (single or SEND_MULTIPLE, with per-app activity targeting)
  - `background()` for blocking work
- **`lib/presets.dart`:** presets plus `makePlan()`, the pure planner that turns size limit × duration into bitrate, resolution and fps. Keep it free of Flutter/IO so it stays unit-testable.
- **`lib/widgets/compress_dialog.dart`:** runs a queue of `CompressJob`s. It re-encodes at a lower bitrate if a file overshoots the limit (up to 3 passes) and retries a failed video once.
- **Screens:**
  - `home_screen.dart`: access state, picking, shares
  - `library_page.dart`: grid, albums, multi-select
  - `editor_screen.dart`
  - `result_screen.dart`
  - `batch_screen.dart` and `batch_result_screen.dart`
- **Shared widgets:**
  - `hold_preview.dart`: hold to preview, slide to scrub
  - `trimmer.dart`
  - `encode_controls.dart`: preset grid and Adjust panel

## Gotchas (each one cost time)

- `dynamic_color` is pinned to 1.8.1. Version 1.9 needs AGP 9 built-in Kotlin and breaks the build on AGP 8.
- Keep draggable controls 32dp or more from the screen edges. Android's back gesture takes edge swipes; the trimmer is inset for this reason.
- The tap that closes the media-permission dialog lands on the freshly shown grid. `LibraryPage` ignores grid input for 700 ms after it appears. Don't remove that.
- An explicit component intent skips intent filters. Before targeting a share activity for multiple videos, check that it declares SEND_MULTIPLE (see `handlers()`). Instagram's DM handler takes one video only.
- Transformer handles source rotation. `Presentation` sizes are display-oriented, and portrait output is encoded landscape with rotation metadata, which is expected.
- Android can't decode 4:4:4 H.264. Encode test clips with ffmpeg `-pix_fmt yuv420p`.
- On a headless emulator (software GPU) exports are about 20× slower. In the first ~20 minutes after boot you can see "Muxer error" or "Player release timed out". Those are emulator artifacts; verify on real hardware.

## Presets and limits

The chat apps' limits come from research (Sept 2026), not official specs, and sources disagreed. If you change a preset, update all three places: `lib/presets.dart`, the table in `README.md`, and the table in `site/index.html`.

## Releasing

1. Move `## [Unreleased]` entries in `CHANGELOG.md` to `## [X.Y.Z] - YYYY-MM-DD`.
2. Bump `version: X.Y.Z+N` in `pubspec.yaml`. N must increase every release.
3. Commit, then `git tag vX.Y.Z && git push origin main vX.Y.Z`.

What `.github/workflows/release.yml` does:
- checks the tag against pubspec
- requires a CHANGELOG section for the version
- runs analyze and tests
- signs with the release key from repo secrets, and refuses any APK not signed by `CN=Ashuku`
- publishes the APK, SHA256SUMS and that CHANGELOG section

Keys: local release builds sign with `android/key.properties` (gitignored), and without it they fall back to the debug key. Never commit a keystore or key.properties. A debug-signed build can't update an installed release.

## Website

`site/` is a static page deployed by `.github/workflows/pages.yml` to https://ashuku.mnow.dev. The custom domain is set in the repo's Pages settings, so the site doesn't need a CNAME file. `site/img/` holds the screenshots shared with the README.

Take public screenshots on a clean emulator loaded with generated sample clips, never on a personal device (album names and videos would leak). Save them with `cwebp -q 82 -resize 540 0`.

## Testing on a device

- Feed a test clip without the gallery:
  1. Install a **debug** build.
  2. Pipe the file into the app cache: `adb exec-in run-as dev.mnow.ashuku sh -c "cat > cache/test/x.mp4" < x.mp4`.
  3. Share it in: `am start -n dev.mnow.ashuku/.MainActivity -a android.intent.action.SEND -t video/mp4 --eu android.intent.extra.STREAM file:///data/user/0/dev.mnow.ashuku/cache/test/x.mp4`.
- A hold gesture over adb: `input motionevent DOWN x y`, a pause, `MOVE`, then `UP`. `input swipe` moves at once, so the long press never triggers.
- To show the permission dialog again: `pm revoke` plus `pm clear-permission-flags dev.mnow.ashuku <perm> user-set user-fixed`.
