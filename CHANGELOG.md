# Changelog

What changed in each Ashuku release. When releasing, move the entries under **Unreleased** into a new version section. The release workflow publishes that section as the GitHub release notes.

## [Unreleased]

## [1.0.1] - 2026-09-28

### Fixed

- In a batch, a video that fails to compress is retried once before it's reported as failed. Setting up the video codec can fail briefly when other apps are using it.
- Sliding to scrub a preview before the video has loaded shows the right time instead of 0:00.
- A batch of one video says "1 video" and "Fits …" instead of "1 videos" and "Each fits …".

## [1.0.0] - 2026-09-27

First release.

- **Video library:** your videos grouped by album, Camera first. Hold a video to preview it with sound, and slide sideways to jump to any point.
- **Editor:** trim with the filmstrip handles or set the start and end at the playhead.
- **Presets:** Messenger (25 MB, 720p), Google Chat (200 MB, 1080p), Instagram DM (25 MB, 60 s), Instagram Reel, and Custom. You can change the size limit, resolution, frame rate and audio.
- **Sized to fit:** exports H.264/AAC on the phone's hardware encoder. It picks the resolution automatically, converts HDR to SDR, and re-encodes if a file comes out over the limit.
- **Batch:** select several videos, compress them with one preset, and send them together.
- **Sending:** send straight to Messenger, Google Chat or Instagram, share anywhere, or save to `Movies/Ashuku`. You can also share videos into Ashuku from other apps.
- **Private:** the app has no internet permission.
