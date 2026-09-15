"""Exercise real encoders and verify the contracts Swift tests depend on."""
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

from prepare_test_media import prepare


class GeneratedMediaContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.directory = tempfile.TemporaryDirectory(prefix="media-contracts-")
        cls.addClassCleanup(cls.directory.cleanup)
        cls.output = Path(cls.directory.name) / "media"
        prepare(cls.output)

    def probe(self, name):
        return json.loads(subprocess.check_output([
            "ffprobe", "-v", "error", "-show_streams", "-show_format", "-show_chapters",
            "-of", "json", str(self.output / name),
        ]))

    def test_baseline_preserves_portrait_playback_and_subtitle_timeline(self):
        info = self.probe("01-h264-aac-baseline.mp4")
        video, audio = info["streams"]
        self.assertEqual((video["codec_name"], video["width"], video["height"], video["r_frame_rate"]),
                         ("h264", 360, 640, "15/1"))
        self.assertEqual(audio["codec_name"], "aac")
        self.assertAlmostEqual(float(info["format"]["duration"]), 12, delta=0.1)
        for language in ("en", "es"):
            self.assertIn("00:00:08,000 --> 00:00:12,000",
                          (self.output / f"01-h264-aac-baseline.{language}.srt").read_text())

    def test_audio_codecs_have_seekable_and_bounded_stream_durations(self):
        for codec in ("ac3", "eac3"):
            for kind, seconds in (("short", 6), ("stream", 24)):
                with self.subTest(codec=codec, kind=kind):
                    info = self.probe(f"{codec}-{kind}.mka")
                    stream, = info["streams"]
                    self.assertEqual((stream["codec_name"], stream["sample_rate"], stream["channels"]),
                                     (codec, "48000", 2))
                    self.assertAlmostEqual(float(info["format"]["duration"]), seconds, delta=0.04)

    def test_subtitle_tracks_contain_bitmap_packets_and_have_finite_duration(self):
        info = self.probe("subtitle-formats.mkv")
        self.assertEqual([s["codec_name"] for s in info["streams"]],
                         ["h264", "ass", "hdmv_pgs_subtitle", "dvd_subtitle", "dvb_subtitle"])
        self.assertAlmostEqual(float(info["format"]["duration"]), 12, delta=0.1)
        packets = json.loads(subprocess.check_output([
            "ffprobe", "-v", "error", "-count_packets", "-select_streams", "s",
            "-show_entries", "stream=nb_read_packets", "-of", "json",
            str(self.output / "subtitle-formats.mkv"),
        ]))["streams"]
        self.assertEqual(len(packets), 4)
        self.assertTrue(all(int(stream["nb_read_packets"]) > 0 for stream in packets))
        for index in (1, 2, 3):
            # Decode each bitmap track and encode it as DVD subtitles. This
            # rejects empty/mislabeled tracks, broken RLE and missing palettes.
            decoded = subprocess.check_output([
                "ffmpeg", "-v", "error", "-nostdin", "-xerror", "-i",
                str(self.output / "subtitle-formats.mkv"), "-map", f"0:s:{index}",
                "-c:s", "dvdsub", "-f", "matroska", "pipe:1",
            ])
            self.assertGreater(len(decoded), 500)

    def test_codec_depth_and_hdr_tags_survive_muxing(self):
        for name, codec, pixel_format in [
            ("codec-hevc-8bit", "hevc", "yuv420p"),
            ("codec-hevc-10bit", "hevc", "yuv420p10le"),
            ("codec-vp9", "vp9", "yuv420p"),
            ("codec-av1", "av1", "yuv420p10le"),
            ("feature-hdr10", "hevc", "yuv420p10le"),
            ("feature-hlg", "hevc", "yuv420p10le"),
            ("feature-120fps", "h264", "yuv420p"),
        ]:
            with self.subTest(name=name):
                stream, = self.probe(name + ".mkv")["streams"]
                self.assertEqual((stream["codec_name"], stream["pix_fmt"]), (codec, pixel_format))
                self.assertEqual((stream["width"], stream["height"]), (320, 180))
                self.assertEqual(stream["r_frame_rate"], "120/1" if name == "feature-120fps" else "24/1")
                if name in ("feature-hdr10", "feature-hlg"):
                    frame = json.loads(subprocess.check_output([
                        "ffprobe", "-v", "error", "-read_intervals", "%+#1", "-show_frames",
                        "-of", "json", str(self.output / (name + ".mkv")),
                    ]))["frames"][0]
                    self.assertEqual(frame["color_primaries"], "bt2020")
                    self.assertEqual(frame["color_transfer"],
                                     "smpte2084" if name == "feature-hdr10" else "arib-std-b67")
                    if name == "feature-hdr10":
                        metadata = {entry["side_data_type"]: entry for entry in frame["side_data_list"]}
                        self.assertEqual(metadata["Content light level metadata"]["max_content"], 1000)
                        self.assertEqual(metadata["Mastering display metadata"]["max_luminance"], "10000000/10000")

    def test_interlaced_field_order_and_frame_rate(self):
        for name, top_first, rate in [
            ("480i-bottom-59.94", 0, "30000/1001"),
            ("576i-top-50", 1, "25/1"),
            ("1080i-top-59.94", 1, "30000/1001"),
        ]:
            with self.subTest(name=name):
                video, = self.probe(name + ".mkv")["streams"]
                self.assertEqual((video["codec_name"], video["r_frame_rate"]), ("mpeg2video", rate))
                frames = json.loads(subprocess.check_output([
                    "ffprobe", "-v", "error", "-read_intervals", "%+#1", "-show_frames",
                    "-show_entries", "frame=interlaced_frame,top_field_first", "-of", "json",
                    str(self.output / (name + ".mkv")),
                ]))["frames"]
                self.assertEqual((frames[0]["interlaced_frame"], frames[0]["top_field_first"]), (1, top_first))


if __name__ == "__main__":
    unittest.main()
