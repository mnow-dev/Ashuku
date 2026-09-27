# Ashuku (圧縮)

Android app that trims and compresses videos so they fit the chat you're sending them to.

- Browse your videos in the app (Camera album first, then other albums). Tap one to edit it, hold it to preview it with sound, or tap ○ on several to batch them.
- Or use the system picker, record a video, or share one in from another app (e.g. Google Photos → Share → Ashuku).
- Trim with the filmstrip handles, or set start/end at the playhead.
- Presets: Messenger, Google Chat, Instagram DM, Instagram Reel, Custom. You can override the size limit, resolution, frame rate, and audio.
- Exports H.264/AAC MP4 on the hardware encoder via Media3 Transformer. HDR is converted to SDR.
- Send straight to the preset's app, use the share sheet, or save to `Movies/Ashuku`.
- Batch: compress several videos with one preset (the size limit applies to each one), then send them all in one share. Instagram DMs only take one video per share, so there you get a send button on each video.

## Install

Download `ashuku-<version>-arm64.apk` from [Releases](https://github.com/mnow-dev/Ashuku/releases) and open it on your phone (allow installs from your browser or file manager when asked). Updates install over the previous version.

Needs Android 10+ on a 64-bit ARM phone (any phone from the last several years).

## How sizing works

`lib/presets.dart` turns the size limit and clip length into a bitrate budget, keeping 8% headroom. In Auto mode it picks the largest resolution that still gets a sensible bits-per-pixel. If the encoder overshoots the limit anyway, `CompressDialog` re-encodes at a proportionally lower bitrate (up to 3 passes).

Preset limits (checked September 2026; apps change these):

| Preset | Limit | Max res | Notes |
|---|---|---|---|
| Messenger | 25 MB | 720p | Meta has been rolling out 100 MB, but not everywhere |
| Google Chat | 200 MB | 1080p | Larger files need a Drive link |
| Instagram DM | 25 MB, 60 s | 1080p | |
| Instagram Reel | 3 min | 1080p | High bitrate, because Instagram re-encodes on upload |

## Code map

- `android/.../VideoEngine.kt`: probe, thumbnails, Media3 export, and saving to MediaStore
- `android/.../MediaLibrary.kt`: MediaStore albums, video lists, and thumbnails for the in-app browser
- `android/.../MainActivity.kt`: the `ashuku/video` method channel, media permissions, incoming shares, and outgoing shares (single or multiple)
- `lib/engine.dart`: Dart side of the channel
- `lib/presets.dart`: presets and the encode planner (unit-tested in `test/planner_test.dart`)
- `lib/screens/`: home/library, editor, result, and batch screens
- `lib/widgets/hold_preview.dart`: hold-to-preview pop-over

## Build

```sh
flutter test
flutter build apk --release --target-platform android-arm64
adb install -r build/app/outputs/flutter-apk/app-release.apk
```

Release builds are signed with the key in `android/key.properties` (gitignored). Without that file they fall back to the debug key, which can't update a phone that has the published release installed.

## Releasing

1. Bump `version:` in `pubspec.yaml` (e.g. `1.1.0+2`; the number after `+` must go up every release).
2. Commit, then tag and push: `git tag v1.1.0 && git push origin main v1.1.0`

The [Release workflow](.github/workflows/release.yml) checks that the tag matches `pubspec.yaml`, runs the analyzer and tests, builds a signed APK, and publishes it with SHA-256 checksums on the Releases page. It needs these repository secrets:

| Secret | Value |
|---|---|
| `ASHUKU_KEYSTORE_BASE64` | `base64 -i ashuku-release.jks` |
| `ASHUKU_KEYSTORE_PASSWORD` | keystore password |
| `ASHUKU_KEY_ALIAS` | `ashuku` |
| `ASHUKU_KEY_PASSWORD` | key password |

Keep a backup of the keystore. Without it, new builds can't update installed copies.
