# Test media

See [TESTING.md](TESTING.md) for test and dependency installation commands.

## Generated media

[prepare_test_media.py](Build/Tests/prepare_test_media.py) runs the generators in `Build/Tests`, reuses valid cached files, and removes obsolete outputs. Keep generated media local. Do not check it in. Generators require FFmpeg, `dovi_tool`, and WebP tools.

[test_generated_media.py](Build/Tests/test_generated_media.py) checks codecs, color tags, metadata, tracks, and timing. Swift tests use the files to check playback and rendering.

| Group          | Fixtures                                                                                                                                                                                      | Covers                                                                                                                                  |
| -------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------- |
| `baseline`     | `baseline.mp4`, `baseline.en.srt`, `baseline.es.srt`                                                                                                                                          | Portrait H.264/AAC video with faststart and sidecar subtitles for most playback, rendering, and PiP tests                          |
| `multitrack`   | `multitrack.mkv`                                                                                                                                                                              | AAC and Opus audio, two SRT tracks, a Japanese ASS track, language and title tags, default flags, overlapping cues, and chapters     |
| `video`        | `video-hevc-8bit.mkv`, `video-vp9.mkv`, `video-av1-10bit.mkv`, `video-h264-120fps.mkv`                                                                                                        | HEVC, VP9, AV1, 10-bit decoding, and high frame rates                                                                                   |
| `color`        | `color-hdr10.mkv`, `color-hlg.mkv`                                                                                                                                                            | 10-bit HEVC with PQ and HLG transfer functions, BT.2020, and HDR10 static metadata                                                      |
| `dolby-vision` | `dolby-vision-p5.mp4`, `dolby-vision-p81.mp4`, `dolby-vision-p84.mp4`, `dolby-vision-p81-declared-extended.ts`, `dolby-vision-p81-extended.ts`, `dolby-vision-p5.rpu`, `dolby-vision-p81.rpu` | Profiles 5, 8.1, and 8.4, CM v4.0 metadata, 120 and 23.976 fps, MPEG-TS signaling, RPU compression, and raw RPUs for native parser tests |
| `interlaced`   | `interlaced-480i-bottom.mkv`, `interlaced-576i-top.mkv`, `interlaced-1080i-top.mkv`                                                                                                           | MPEG-2 field coding with both field orders and the NTSC, PAL, and HD rates                                                              |
| `audio`        | `audio-ac3-stereo.mka`, `audio-ac3-5.1.mka`, `audio-eac3-stereo.mka`, `audio-eac3-5.1.mka`, `audio-pcm-mono.mka`, `audio-pcm-stereo.mka`, `audio-pcm-5.1.mka`, `audio-pcm-7.1.mka`            | AC-3 and E-AC-3 passthrough, plus PCM speaker layouts. The 24-second 5.1 files outlast native output buffering.                         |
| `subtitles`    | `subtitles.mkv`                                                                                                                                                                               | One track each of ASS, PGS, DVD, and DVB subtitles on a portrait canvas                                                                 |
| `image`        | `image-webp-still.webp`, `image-webp-animated.webp`                                                                                                                                           | Lossless still and animated WebP with partial frames and variable timing                                                                |

## Add media

Reuse an existing group and fixture when possible. Add a file for a different codec, container, duration, field order, or damaged data. Add a group for a new kind of test, such as streaming.

1. Update or add a generator in `Build/Tests`.
2. Register its output files in [prepare_test_media.py](Build/Tests/prepare_test_media.py).
3. Add checks for the files in [test_generated_media.py](Build/Tests/test_generated_media.py).
4. Add a playback test to the relevant Swift suite.

Name files `<group>-<variant>.<ext>`, or `<group>.<ext>` when there is only one. For a bug found in a real file, try to generate a small clip that reproduces it.

## Gaps

The Profile 5 clip tests Dolby Vision output selection and metadata, but cannot validate IPT-PQ-c2 color accuracy because its base layer is not encoded that way.

The generated files do not yet cover these cases:

- `video`: H.264 High 10 and 4:2:2, HEVC 4:2:2 and 12-bit, VP9 profile 2, AV1 film grain, VP8 and VP9 alpha, ProRes, MPEG-2 soft telecine, odd dimensions, anamorphic aspect ratios, rotation, variable frame rate.
- `color`: BT.601 and Display P3, full range, untagged video, container tags that disagree with the bitstream, HDR10 without static metadata, HDR10+.
- `dolby-vision`: Profile 8.2, Profile 10 (AV1), CM v2.9, missing or corrupt RPUs on some frames, a configuration record without RPUs and RPUs without one.
- `interlaced`: H.264 field and MBAFF coding, hard telecine, mixed progressive and interlaced.
- `audio`: AAC multichannel, MP3, FLAC, ALAC, Opus multichannel, TrueHD, DTS core, PCM s24 and f32, uncommon sample rates, midstream layout changes.
- `subtitles.mkv` and `multitrack.mkv`: WebVTT, `mov_text`, CEA-608 and CEA-708 captions, forced and hearing-impaired flags, right-to-left and vertical text, non-UTF-8 sidecars.
- Containers: fragmented MP4, MP4 with `moov` at the end, edit lists, MOV rotation and timecode, M2TS, timestamp wrap, AVI, WebM, OGG, raw elementary streams.
- Streaming: DASH and HLS with TS and fMP4 segments, variants, WebVTT renditions, and discontinuities.
- Damaged files: truncation, bit flips, missing `moov` or PMT, wrong header duration.
