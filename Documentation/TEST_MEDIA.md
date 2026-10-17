# Test media

Apple and Android tests share generated fixtures in `.build/test-media`. See [Testing](TESTING.md) for dependency installation and test commands.

## Generated fixtures

Run `make media`. [prepare_test_media.py](../Build/Tests/prepare_test_media.py) generates files, reuses valid cached outputs, and removes obsolete fixtures. Keep generated media outside version control.

[test_generated_media.py](../Build/Tests/test_generated_media.py) checks codecs, color tags, metadata, tracks, and timing before playback tests use the files.

| Group          | Coverage                                                                                                     |
| -------------- | ------------------------------------------------------------------------------------------------------------ |
| `baseline`     | Short portrait H.264 video with audio and sidecar subtitles                                                  |
| `multitrack`   | Audio and subtitle selection, language tags, overlapping cues, and chapters                                  |
| `video`        | HEVC, VP9, AV1, 10-bit decoding, and high frame rates                                                        |
| `color`        | HDR10 and HLG transfer functions with wide-color metadata                                                    |
| `dolby-vision` | Profiles 5, 8.1, and 8.4, compressed metadata, transport-stream signaling, and raw metadata for parser tests |
| `interlaced`   | Standard-definition and high-definition MPEG-2 with both field orders                                        |
| `audio`        | AC-3, E-AC-3, and PCM speaker layouts from mono to 7.1                                                       |
| `subtitles`    | Styled ASS and bitmap PGS, DVD, and DVB subtitles                                                            |
| `image`        | Still and animated WebP with partial frames and variable timing                                              |

The generator is the source of truth for filenames. Use `make help TARGET=media` for group and output options.

## Add fixtures

Reuse a group and fixture when possible. Add media when a test needs a different codec, container, timing pattern, or failure case.

1. Update or add a generator in `Build/Tests`.
2. Register its outputs in [prepare_test_media.py](../Build/Tests/prepare_test_media.py).
3. Check the outputs in [test_generated_media.py](../Build/Tests/test_generated_media.py).
4. Add playback assertions to the relevant suite.

Name files `<group>-<variant>.<ext>`, or `<group>.<ext>` when there's only one. For a bug found in a real file, generate a small reproducer when possible.

## Reference media

The generated Dolby Vision Profile 5 clip exercises metadata and output selection. Its base layer doesn't use the required IPT-PQ-c2 color encoding, so it can't establish color accuracy.

Color tests use an optional 1080p Profile 5 chart. Place it at `Example/Sources/MPVUIExample/Resources/Media/dolby-vision-p5-chart.mp4`, or set `MPVUI_DOLBY_VISION_CHART` to its path. Tests explain the skip when it's absent. [Android media preparation](../Build/Android/prepare_test_media.py) also derives an untagged stream from this chart for metadata detection tests.

Keep externally supplied reference media local. Automated fixtures don't establish physical display output, audio-route support, or complete codec coverage. Add focused fixtures as new behaviors require them.
