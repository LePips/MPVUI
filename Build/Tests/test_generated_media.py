"""Exercise real encoders and verify the contracts Swift tests depend on."""

import json
from pathlib import Path
import subprocess
import tempfile
import unittest

from prepare_test_media import GROUPS, prepare


class GeneratedMediaContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.directory = tempfile.TemporaryDirectory(prefix="media-contracts-")
        cls.addClassCleanup(cls.directory.cleanup)
        cls.output = Path(cls.directory.name) / "media"
        prepare(cls.output)

    def probe(self, name):
        return json.loads(
            subprocess.check_output(
                [
                    "ffprobe",
                    "-v",
                    "error",
                    "-show_streams",
                    "-show_format",
                    "-show_chapters",
                    "-of",
                    "json",
                    str(self.output / name),
                ]
            )
        )

    def first_frame(self, name):
        return json.loads(
            subprocess.check_output(
                [
                    "ffprobe",
                    "-v",
                    "error",
                    "-read_intervals",
                    "%+#1",
                    "-show_frames",
                    "-of",
                    "json",
                    str(self.output / name),
                ]
            )
        )["frames"][0]

    def test_every_registered_file_is_generated(self):
        names = {name for _, files in GROUPS.values() for name in files}
        self.assertEqual({path.name for path in self.output.iterdir()}, names)

    def test_baseline_preserves_portrait_playback_and_subtitle_timeline(self):
        info = self.probe("baseline.mp4")
        video, audio = info["streams"]
        self.assertEqual((video["codec_name"], video["width"], video["height"], video["r_frame_rate"]), ("h264", 360, 640, "15/1"))
        self.assertEqual(audio["codec_name"], "aac")
        self.assertAlmostEqual(float(info["format"]["duration"]), 12, delta=0.1)
        for language in ("en", "es"):
            self.assertIn("00:00:08,000 --> 00:00:12,000", (self.output / f"baseline.{language}.srt").read_text())

    def test_multitrack_tracks_cue_timing_and_chapters(self):
        info = self.probe("multitrack.mkv")
        self.assertEqual(
            [(s["codec_name"], s.get("tags", {}).get("language")) for s in info["streams"]],
            [
                ("h264", None),
                ("aac", "eng"),
                ("opus", "spa"),
                ("subrip", "eng"),
                ("subrip", "eng"),
                ("ass", "jpn"),
            ],
        )
        packets = json.loads(
            subprocess.check_output(
                [
                    "ffprobe",
                    "-v",
                    "error",
                    "-select_streams",
                    "s:0",
                    "-show_packets",
                    "-show_entries",
                    "packet=pts_time,duration_time",
                    "-of",
                    "json",
                    str(self.output / "multitrack.mkv"),
                ]
            )
        )["packets"]
        # Overlapping and long cues exercise subtitle seeking.
        self.assertEqual([(float(p["pts_time"]), float(p["duration_time"])) for p in packets], [(1, 4), (1, 17), (3, 3), (19, 1)])
        self.assertEqual(
            [(float(c["start_time"]), c["tags"]["title"]) for c in info["chapters"]], [(0, "Opening"), (4, "Middle"), (8, "Ending")]
        )

    def test_video_codecs_depths_and_frame_rates(self):
        for name, codec, pixel_format, rate in [
            ("video-hevc-8bit", "hevc", "yuv420p", "24/1"),
            ("video-vp9", "vp9", "yuv420p", "24/1"),
            ("video-av1-10bit", "av1", "yuv420p10le", "24/1"),
            ("video-h264-120fps", "h264", "yuv420p", "120/1"),
        ]:
            with self.subTest(name=name):
                (stream,) = self.probe(name + ".mkv")["streams"]
                self.assertEqual((stream["codec_name"], stream["pix_fmt"], stream["r_frame_rate"]), (codec, pixel_format, rate))
                self.assertEqual((stream["width"], stream["height"]), (320, 180))

    def test_startup_video_has_audio_and_widely_spaced_keyframes(self):
        name = "video-h264-long-gop.mkv"
        video, audio = self.probe(name)["streams"]
        self.assertEqual((video["codec_name"], video["r_frame_rate"], audio["codec_name"]), ("h264", "24/1", "aac"))
        packets = json.loads(
            subprocess.check_output(
                [
                    "ffprobe",
                    "-v",
                    "error",
                    "-select_streams",
                    "v:0",
                    "-show_packets",
                    "-show_entries",
                    "packet=pts_time,flags",
                    "-of",
                    "json",
                    str(self.output / name),
                ]
            )
        )["packets"]
        keyframes = [float(packet["pts_time"]) for packet in packets if "K" in packet["flags"]]
        self.assertEqual(len(keyframes), 2)
        self.assertAlmostEqual(keyframes[1] - keyframes[0], 10, delta=0.01)

    def test_color_transfer_tags_and_static_metadata_survive_muxing(self):
        for name, transfer in [("color-hdr10", "smpte2084"), ("color-hlg", "arib-std-b67")]:
            with self.subTest(name=name):
                info = self.probe(name + ".mkv")
                (stream,) = info["streams"]
                self.assertEqual(
                    (stream["codec_name"], stream["pix_fmt"], stream["width"], stream["height"]), ("hevc", "yuv420p10le", 320, 180)
                )
                self.assertAlmostEqual(float(info["format"]["duration"]), 10, delta=0.1)
                frame = self.first_frame(name + ".mkv")
                self.assertEqual((frame["color_primaries"], frame["color_transfer"]), ("bt2020", transfer))
        metadata = {entry["side_data_type"]: entry for entry in self.first_frame("color-hdr10.mkv")["side_data_list"]}
        self.assertEqual(metadata["Content light level metadata"]["max_content"], 1000)
        self.assertEqual(metadata["Mastering display metadata"]["max_luminance"], "10000000/10000")

    def test_dolby_vision_configuration_and_rpu_compression(self):
        rpu_bytes = {}
        for name, profile, compatibility, compression, transfer, rate in [
            ("dolby-vision-p5.mp4", 5, 0, "none", None, "120/1"),
            ("dolby-vision-p81.mp4", 8, 1, "none", "smpte2084", "120/1"),
            ("dolby-vision-p84.mp4", 8, 4, "none", "arib-std-b67", "24000/1001"),
            ("dolby-vision-p81-declared-extended.ts", 8, 1, "extended", "smpte2084", "120/1"),
            ("dolby-vision-p81-extended.ts", 8, 1, "extended", "smpte2084", "120/1"),
        ]:
            with self.subTest(name=name):
                video = self.probe(name)["streams"][0]
                record = next(entry for entry in video["side_data_list"] if "dv_profile" in entry)
                self.assertEqual((video["codec_name"], video["pix_fmt"], video["r_frame_rate"]), ("hevc", "yuv420p10le", rate))
                self.assertEqual(video.get("color_transfer", "unknown"), transfer or "unknown")
                self.assertEqual(
                    (record["dv_profile"], record["dv_bl_signal_compatibility_id"], record["dv_md_compression"]),
                    (profile, compatibility, compression),
                )
                frames = json.loads(
                    subprocess.check_output(
                        [
                            "ffprobe",
                            "-v",
                            "error",
                            "-select_streams",
                            "v:0",
                            "-show_frames",
                            "-show_entries",
                            "frame_side_data=side_data_type",
                            "-of",
                            "json",
                            str(self.output / name),
                        ]
                    )
                )["frames"]
                (packets,) = json.loads(
                    subprocess.check_output(
                        [
                            "ffprobe",
                            "-v",
                            "error",
                            "-select_streams",
                            "v:0",
                            "-count_packets",
                            "-show_entries",
                            "stream=nb_read_packets",
                            "-of",
                            "json",
                            str(self.output / name),
                        ]
                    )
                )["streams"]
                self.assertEqual(int(packets["nb_read_packets"]), 240)
                self.assertTrue(
                    frames
                    and all(
                        any(entry["side_data_type"] == "Dolby Vision Metadata" for entry in frame.get("side_data_list", []))
                        for frame in frames
                    )
                )
                rpu = subprocess.run(
                    ["ffmpeg", "-v", "error", "-i", str(self.output / name), "-map", "0:v", "-c", "copy", "-f", "hevc", "pipe:1"],
                    check=True,
                    capture_output=True,
                ).stdout
                rpu_bytes[name] = sum(len(unit) for unit in rpu.split(b"\x00\x00\x01")[1:] if unit[0] >> 1 & 0x3F == 62)
        # Declared compression alone keeps standalone RPUs; the extended stream references earlier RPUs.
        self.assertEqual(rpu_bytes["dolby-vision-p81-declared-extended.ts"], rpu_bytes["dolby-vision-p81.mp4"])
        self.assertLess(rpu_bytes["dolby-vision-p81-extended.ts"], rpu_bytes["dolby-vision-p81.mp4"] * 0.6)
        for name in ("dolby-vision-p81-declared-extended.ts", "dolby-vision-p81-extended.ts"):
            audio = self.probe(name)["streams"][1]
            self.assertEqual((audio["codec_name"], audio["channels"]), ("aac", 1))

    def test_dolby_vision_parser_rpus_are_unescaped_payloads(self):
        for name in ("dolby-vision-p5.rpu", "dolby-vision-p81.rpu"):
            with self.subTest(name=name):
                data = (self.output / name).read_bytes()
                self.assertEqual(data[0], 0x19)
                self.assertNotIn(b"\x00\x00\x00\x01", data)

    def test_interlaced_field_order_and_frame_rate(self):
        for name, top_first, rate in [
            ("interlaced-480i-bottom", 0, "30000/1001"),
            ("interlaced-576i-top", 1, "25/1"),
            ("interlaced-1080i-top", 1, "30000/1001"),
        ]:
            with self.subTest(name=name):
                (video,) = self.probe(name + ".mkv")["streams"]
                self.assertEqual((video["codec_name"], video["r_frame_rate"]), ("mpeg2video", rate))
                frame = self.first_frame(name + ".mkv")
                self.assertEqual((frame["interlaced_frame"], frame["top_field_first"]), (1, top_first))

    def test_audio_codecs_layouts_and_durations(self):
        for codec, layout, channels, seconds in [
            ("ac3", "stereo", 2, 6),
            ("ac3", "5.1", 6, 24),
            ("eac3", "stereo", 2, 6),
            ("eac3", "5.1", 6, 24),
            ("pcm", "mono", 1, 6),
            ("pcm", "stereo", 2, 6),
            ("pcm", "5.1", 6, 6),
            ("pcm", "7.1", 8, 6),
        ]:
            with self.subTest(codec=codec, layout=layout):
                info = self.probe(f"audio-{codec}-{layout}.mka")
                (stream,) = info["streams"]
                self.assertEqual(
                    (stream["codec_name"], stream["sample_rate"], stream["channels"]),
                    ("pcm_s16le" if codec == "pcm" else codec, "48000", channels),
                )
                self.assertAlmostEqual(float(info["format"]["duration"]), seconds, delta=0.04)

    def test_subtitle_tracks_contain_bitmap_packets_and_have_finite_duration(self):
        info = self.probe("subtitles.mkv")
        self.assertEqual(
            [s["codec_name"] for s in info["streams"]],
            ["h264", "ass", "hdmv_pgs_subtitle", "dvd_subtitle", "dvb_subtitle", "hdmv_pgs_subtitle"],
        )
        self.assertEqual(info["streams"][-1]["tags"]["title"], "Color channel order")
        self.assertAlmostEqual(float(info["format"]["duration"]), 12, delta=0.1)
        packets = json.loads(
            subprocess.check_output(
                [
                    "ffprobe",
                    "-v",
                    "error",
                    "-count_packets",
                    "-select_streams",
                    "s",
                    "-show_entries",
                    "stream=nb_read_packets",
                    "-of",
                    "json",
                    str(self.output / "subtitles.mkv"),
                ]
            )
        )["streams"]
        self.assertEqual(len(packets), 5)
        self.assertTrue(all(int(stream["nb_read_packets"]) > 0 for stream in packets))
        for index in (1, 2, 3, 4):
            # Decode each bitmap track and encode it as DVD subtitles. This
            # rejects empty/mislabeled tracks, broken RLE and missing palettes.
            decoded = subprocess.check_output(
                [
                    "ffmpeg",
                    "-v",
                    "error",
                    "-nostdin",
                    "-xerror",
                    "-i",
                    str(self.output / "subtitles.mkv"),
                    "-map",
                    f"0:s:{index}",
                    "-c:s",
                    "dvdsub",
                    "-f",
                    "matroska",
                    "pipe:1",
                ]
            )
            self.assertGreater(len(decoded), 500)

    def test_images_decode_with_expected_frame_counts(self):
        for name, frames in [("image-webp-still.webp", 1), ("image-webp-animated.webp", 3)]:
            with self.subTest(name=name):
                header = (self.output / name).read_bytes()[:16]
                self.assertEqual((header[:4], header[8:12]), (b"RIFF", b"WEBP"))
                self.assertEqual((self.output / name).read_bytes().count(b"ANMF"), 0 if frames == 1 else frames)


if __name__ == "__main__":
    unittest.main()
