"""Exercise real encoders and verify the contracts playback tests depend on."""

import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from xml.etree import ElementTree

from generate_codecs import (
    AVC_CROP,
    AV1_FILM_GRAIN,
    CEA608_MCC,
    CEA608_MOV,
    CEA608_RCWT,
    CEA608_SCC,
    CEA608_TS,
    DATAGRAM_TS,
    DISPLAY_ROTATION,
    HEVC_UHD,
    INTERLACED_AVC,
    MANIFEST,
    MP3_ADU,
    MPEG_TS_PROGRAM_CHANGES,
    MPEG_TS_PROGRAMS,
    MPEG_TS_WRAP,
    SUBTITLE_MATROSKA,
    SUBTITLE_VIDEO,
    SUBTITLE_VTT,
    SUBTITLE_WEBM,
    VC1_CONTAINERS,
    VC1_STREAM,
    VIDEO_ALPHA,
    VFR_ANAMORPHIC,
    WEBM_DASH_INDEX,
    WEBM_TRUNCATED_CLUSTER,
    WMV3_CONTAINERS,
    WMV3_STREAM,
)
from prepare_test_media import GROUPS, prepare


class GeneratedMediaContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.directory = tempfile.TemporaryDirectory(prefix="media-contracts-")
        cls.addClassCleanup(cls.directory.cleanup)
        cls.output = Path(cls.directory.name) / "media"
        prepare(cls.output)

    def probe(self, name, forced_format="", parameters=""):
        input_options = ["-f", forced_format] if forced_format else []
        for parameter in filter(None, parameters.split(",")):
            key, value = parameter.split("=", 1)
            input_options.extend((f"-{key}", value))
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
                    *input_options,
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

    def probe_mp4_fragment(self, init, first):
        fragments = (self.output / init).read_bytes() + (self.output / first).read_bytes()
        with tempfile.NamedTemporaryFile(suffix=".mp4", dir=self.output.parent) as file:
            file.write(fragments)
            file.flush()
            return self.probe(Path(file.name))["streams"]

    def test_every_registered_file_is_generated(self):
        names = {name for _, files in GROUPS.values() for name in files}
        files = {path.relative_to(self.output).as_posix() for path in self.output.rglob("*") if path.is_file()}
        self.assertEqual(files, names)

    def test_authored_video_preserves_codec_profiles_and_pixel_formats(self):
        catalog = json.loads((self.output / MANIFEST).read_text())
        for clip in catalog["chromaVideo"]:
            with self.subTest(file=clip["file"]):
                stream = self.probe(clip["file"])["streams"][0]
                self.assertEqual(stream["codec_name"], clip["codec"])
                self.assertEqual(stream["profile"], clip["profile"])
                self.assertEqual(stream["pix_fmt"], clip["pixelFormat"])
        for clip in catalog["proresRAWVideo"]:
            with self.subTest(file=clip["file"]):
                stream = self.probe(clip["file"])["streams"][0]
                self.assertEqual((stream["codec_name"], stream["profile"]), ("prores_raw", clip["profile"]))
                frame = self.first_frame(clip["file"])
                self.assertEqual((frame["width"], frame["height"], frame["pix_fmt"]), (96, 64, "bayer_rggb16le"))
        for clip in catalog["avs3Video"]:
            with self.subTest(file=clip["file"]):
                stream = self.probe(clip["file"])["streams"][0]
                self.assertEqual(stream["codec_name"], "avs3")
                self.assertEqual(stream["r_frame_rate"], "24/1")

    def test_remuxed_fixtures_keep_their_source_stream(self):
        catalog = json.loads((self.output / MANIFEST).read_text())
        for group, kind in (("mappedAudio", "audio"), ("mappedVideo", "video")):
            sources = {entry["file"]: entry for entry in catalog[kind]}
            mappings = set()
            for clip in catalog[group]:
                with self.subTest(file=clip["file"]):
                    key = (clip["mapping"], clip["codec"])
                    self.assertNotIn(key, mappings)
                    mappings.add(key)
                    source = sources[clip["source"]]
                    for attribute in ("codec", "decoder", "width", "height"):
                        self.assertEqual(clip[attribute], source[attribute])
                    self.assertGreater((self.output / clip["file"]).stat().st_size, 0)

    def test_matroska_lacing_preserves_packet_sizes_and_timestamps(self):
        fixtures = json.loads((self.output / "matroska-lacing.json").read_text())
        self.assertEqual(set(fixtures), {"fixed", "xiph", "ebml", "flac-xiph", "flac-ebml"})
        for mode, clip in fixtures.items():
            with self.subTest(lacing=mode):
                result = json.loads(
                    subprocess.check_output(
                        [
                            "ffprobe",
                            "-v",
                            "error",
                            "-show_entries",
                            "packet=pts,duration,size",
                            "-of",
                            "json",
                            str(self.output / clip["file"]),
                        ]
                    )
                )
                packets = result["packets"]
                self.assertEqual([(packet["pts"], packet["duration"]) for packet in packets], [(i * 20, 20) for i in range(60)])
                sizes = {packet["size"] for packet in packets}
                if mode.startswith("flac-"):
                    self.assertGreater(len(sizes), 1)
                else:
                    self.assertEqual(sizes, {"1920"})

    def test_legacy_text_fixtures_carry_both_cues_at_the_authored_times(self):
        catalog = json.loads((self.output / "text-subtitles.json").read_text())
        for clip in catalog["cases"]:
            with self.subTest(format=clip["format"]):
                info = json.loads(
                    subprocess.check_output(
                        [
                            "ffprobe",
                            "-v",
                            "error",
                            "-show_entries",
                            "packet=pts_time,duration_time:format=format_name:stream=codec_name",
                            "-of",
                            "json",
                            str(self.output / clip["file"]),
                        ]
                    )
                )
                self.assertEqual(info["format"]["format_name"], clip["format"])
                self.assertEqual(info["streams"][0]["codec_name"], clip["codec"])
                starts = {packet["pts_time"]: packet.get("duration_time") for packet in info["packets"]}
                offset = clip.get("timeOffset", 0)
                self.assertEqual(starts.get(f"{1 + offset:.6f}"), "1.000000")
                self.assertEqual(starts.get(f"{3 + offset:.6f}"), "1.000000")

    def test_transport_fixtures_carry_two_programs_and_a_pts_wrap(self):
        programs = json.loads(
            subprocess.check_output(
                [
                    "ffprobe",
                    "-v",
                    "error",
                    "-show_programs",
                    "-of",
                    "json",
                    self.output / MPEG_TS_PROGRAMS,
                ]
            )
        )["programs"]
        self.assertEqual(
            [(program["program_id"], [(track["id"], track["codec_name"]) for track in program["streams"]]) for program in programs],
            [(101, [("0x100", "h264"), ("0x101", "aac")]), (202, [("0x200", "mpeg2video"), ("0x201", "mp2")])],
        )
        packets = json.loads(
            subprocess.check_output(
                [
                    "ffprobe",
                    "-v",
                    "error",
                    "-select_streams",
                    "v:0",
                    "-show_entries",
                    "packet=pts",
                    "-of",
                    "json",
                    self.output / MPEG_TS_WRAP,
                ]
            )
        )["packets"]
        modulus = 1 << 33
        timestamps = [int(packet["pts"]) % modulus for packet in packets]
        unwrapped = [(value - timestamps[0]) % modulus for value in timestamps]
        self.assertEqual(unwrapped, list(range(0, 3 * 90000, 3750)))
        self.assertAlmostEqual(timestamps[0], modulus - 90000, delta=2)
        self.assertLess(timestamps[-1], 2 * 90000)

    def test_transport_pat_versions_add_and_remove_a_program(self):
        data = (self.output / MPEG_TS_PROGRAM_CHANGES).read_bytes()
        self.assertEqual(len(data) % 188, 0)
        changes = []
        for offset in range(0, len(data), 188):
            packet = data[offset : offset + 188]
            self.assertEqual(packet[0], 0x47)
            if packet[1:3] != b"\x40\x00" or not packet[3] & 0x10:
                continue
            payload = 5 + packet[4] if packet[3] & 0x20 else 4
            start = payload + 1 + packet[payload]
            self.assertEqual(packet[start], 0)
            length = ((packet[start + 1] & 0x0F) << 8) | packet[start + 2]
            programs = tuple(int.from_bytes(packet[index : index + 2], "big") for index in range(start + 8, start + 3 + length - 4, 4))
            change = ((packet[start + 5] >> 1) & 0x1F, programs)
            if not changes or changes[-1] != change:
                changes.append(change)
        self.assertEqual(changes, [(0, (101,)), (1, (101, 202)), (2, (101,))])

    def test_avc_timing_fixtures_preserve_pts_aspect_rotation_and_field_order(self):
        timing = json.loads(
            subprocess.check_output(
                [
                    "ffprobe",
                    "-v",
                    "error",
                    "-show_entries",
                    "packet=pts_time:stream=codec_name,sample_aspect_ratio",
                    "-of",
                    "json",
                    self.output / VFR_ANAMORPHIC,
                ]
            )
        )
        self.assertEqual(timing["streams"], [{"codec_name": "h264", "sample_aspect_ratio": "3:2"}])
        self.assertEqual(
            [float(packet["pts_time"]) for packet in timing["packets"]],
            [0.0, 0.25, 0.75, 1.0, 1.125, 1.75, 2.0, 2.25, 2.75],
        )

        rotated = self.probe(DISPLAY_ROTATION)["streams"][0]
        self.assertEqual((rotated["codec_name"], rotated["width"], rotated["height"]), ("h264", 192, 108))
        self.assertEqual([data["rotation"] for data in rotated["side_data_list"] if data["side_data_type"] == "Display Matrix"], [90])

        for order, filename in INTERLACED_AVC.items():
            with self.subTest(order=order):
                stream = self.probe(filename)["streams"][0]
                self.assertEqual(stream["codec_name"], "h264")
                self.assertEqual(stream["r_frame_rate"], "24/1")
                self.assertEqual(stream["field_order"], "tt" if order == "top" else "bb")
                frame = self.first_frame(filename)
                self.assertEqual(frame["interlaced_frame"], 1)
                self.assertEqual(frame["top_field_first"], int(order == "top"))

    def test_cropped_avc_preserves_the_coded_frame_and_explicit_conformance_window(self):
        (cropped,) = self.probe(AVC_CROP)["streams"]
        self.assertEqual((cropped["codec_name"], cropped["width"], cropped["height"]), ("h264", 160, 128))
        coded = subprocess.check_output(
            [
                "ffprobe",
                "-v",
                "error",
                "-apply_cropping",
                "0",
                "-select_streams",
                "v:0",
                "-read_intervals",
                "%+#1",
                "-show_entries",
                "frame=width,height",
                "-of",
                "json",
                self.output / AVC_CROP,
            ],
            text=True,
        )
        self.assertEqual(json.loads(coded)["frames"][0]["width"], 192)
        self.assertEqual(json.loads(coded)["frames"][0]["height"], 144)

    def test_uhd_hevc_carries_main10_b_frames_and_a_uhd_bitrate(self):
        (video,) = self.probe(HEVC_UHD)["streams"]
        self.assertEqual((video["codec_name"], video["profile"], video["pix_fmt"]), ("hevc", "Main 10", "yuv420p10le"))
        self.assertEqual((video["width"], video["height"], int(video["nb_frames"])), (3840, 2160, 18))
        self.assertGreaterEqual(int(video["has_b_frames"]), 2)
        self.assertGreaterEqual(int(video["bit_rate"]), 20_000_000)

    def test_decoder_fixtures_carry_the_declared_streams(self):
        catalog = json.loads((self.output / MANIFEST).read_text())
        video_groups = ("video", "colorVideo", "apv", "chromaVideo", "images")
        for group, kind in (("audio", "audio"), *((name, "video") for name in video_groups)):
            for clip in catalog[group]:
                with self.subTest(file=clip["file"], decoder=clip["decoder"]):
                    info = self.probe(clip["file"], clip["forcedFormat"], clip["mpvOptions"].get("demuxer-lavf-o", ""))
                    format_name = "matroska" if clip["format"] == "mkv" else clip["format"]
                    if clip["forcedFormat"]:
                        format_name = clip["forcedFormat"]
                    self.assertIn(format_name, info["format"]["format_name"].split(","))
                    tracks = [stream for stream in info["streams"] if stream["codec_type"] == kind]
                    if clip["codec"] == "truehd" and clip["format"] == "mpegts":
                        track, compatibility_track = tracks
                        self.assertEqual(compatibility_track["codec_name"], "ac3")
                        self.assertEqual(compatibility_track["id"], track["id"])
                    else:
                        (track,) = tracks
                    self.assertEqual(track["codec_name"], clip["codec"])
                    if kind == "video":
                        self.assertEqual((track["width"], track["height"]), (clip["width"], clip["height"]))
                        if "pixelFormat" in clip:
                            self.assertEqual(track["pix_fmt"], clip["pixelFormat"])
                        if "profile" in clip:
                            self.assertEqual(track["profile"], clip["profile"])

        for pair in catalog["paired"]:
            with self.subTest(file=pair["file"]):
                info = self.probe(pair["file"])
                format_name = "webm" if pair["format"] == "mkv" else pair["format"]
                self.assertIn(format_name, info["format"]["format_name"].split(","))
                picture, sound = info["streams"]
                self.assertEqual((picture["codec_type"], picture["codec_name"]), ("video", pair["videoCodec"]))
                self.assertEqual((sound["codec_type"], sound["codec_name"]), ("audio", pair["audioCodec"]))
                self.assertAlmostEqual(float(info["format"]["duration"]), 2, delta=0.1)

        surround = catalog["surround"]
        (audio,) = self.probe(surround["file"])["streams"]
        self.assertEqual((audio["codec_name"], audio["channel_layout"], audio["bits_per_raw_sample"]), ("flac", "5.1", "24"))
        self.assertEqual((int(audio["sample_rate"]), audio["channels"]), (surround["sampleRate"], surround["channels"]))
        raw = subprocess.check_output(
            [
                "ffmpeg",
                "-v",
                "error",
                "-i",
                str(self.output / surround["file"]),
                "-f",
                "s32le",
                "pipe:1",
            ]
        )
        frame_size = audio["channels"] * 4
        self.assertEqual(len(raw), surround["frames"] * frame_size)
        self.assertEqual(hashlib.sha256(raw).hexdigest(), surround["sha256"])
        self.assertEqual(hashlib.sha256(raw[surround["seekStartFrame"] * frame_size :]).hexdigest(), surround["seekSha256"])

        self.assertEqual({case["pcm"]["sampleRate"] for case in catalog["audioRates"]}, {44100, 96000})
        for case in catalog["audioRates"]:
            pcm = case["pcm"]
            with self.subTest(file=pcm["file"]):
                info = self.probe(pcm["file"])
                (audio,) = info["streams"]
                self.assertIn(case["format"], info["format"]["format_name"].split(","))
                self.assertEqual((audio["codec_name"], audio["bits_per_raw_sample"]), (case["codec"], "24"))
                self.assertEqual((int(audio["sample_rate"]), audio["channels"]), (pcm["sampleRate"], 2))
                raw = subprocess.check_output(["ffmpeg", "-v", "error", "-i", str(self.output / pcm["file"]), "-f", "s32le", "pipe:1"])
                self.assertEqual(len(raw), pcm["frames"] * 8)
                self.assertEqual(hashlib.sha256(raw).hexdigest(), pcm["sha256"])

        indexed = self.probe(WEBM_DASH_INDEX, "webm_dash_manifest")
        self.assertEqual(indexed["format"]["format_name"], "webm_dash_manifest")
        (track,) = indexed["streams"]
        self.assertEqual(track["codec_name"], "vp9")
        self.assertEqual(track["tags"]["webm_dash_manifest_cue_timestamps"], "0,250,500,750")

        for entry in catalog["segmented"]:
            with self.subTest(file=entry["file"]):
                if entry["format"] == "dash":
                    # Host FFmpeg may lack the DASH demuxer. Probe the actual fragmented MP4 below the manifest.
                    init, first, *_ = entry["parts"]
                    streams = self.probe_mp4_fragment(init, first)
                elif entry["format"] != "edl/mov":
                    streams = self.probe(entry["file"])["streams"]
                else:
                    continue  # EDL is interpreted by mpv, which exercises this manifest during playback.
                (track,) = streams
                self.assertEqual((track["codec_name"], track["width"], track["height"]), ("h264", 176, 144))

        self.assertEqual([track["codec_name"] for track in self.probe(SUBTITLE_VIDEO)["streams"]], ["h264", "mov_text"])
        self.assertEqual(self.probe(SUBTITLE_VTT)["streams"][0]["codec_name"], "webvtt")
        video, text, captions = self.probe(SUBTITLE_WEBM)["streams"]
        self.assertEqual([stream["codec_name"] for stream in (video, text, captions)], ["vp9", "webvtt", "webvtt"])
        self.assertEqual(text["disposition"]["default"], 1)
        self.assertEqual(captions["disposition"]["captions"], 1)
        for name in (SUBTITLE_WEBM, SUBTITLE_MATROSKA):
            with self.subTest(name=name):
                data = (self.output / name).read_bytes()
                self.assertIn(b"position:25%,line-left line:80%,end size:40% align:start\nWebVTT first cue", data)
                self.assertIn(
                    "position:75%,line-right line:20%,start size:30% align:start\nכתוביות בעברית".encode(),
                    data,
                )

    def test_truncated_webm_has_both_tracks_and_only_the_first_complete_cluster(self):
        complete = "codecs-paired-vp9-opus.webm"
        truncated = (self.output / WEBM_TRUNCATED_CLUSTER).read_bytes()
        self.assertTrue((self.output / complete).read_bytes().startswith(truncated))
        tracks = self.probe(WEBM_TRUNCATED_CLUSTER)["streams"]
        self.assertEqual([track["codec_name"] for track in tracks], ["vp9", "opus"])
        packets = json.loads(
            subprocess.check_output(["ffprobe", "-v", "quiet", "-show_packets", "-of", "json", self.output / WEBM_TRUNCATED_CLUSTER])
        )["packets"]
        for track in (0, 1):
            times = [float(packet["pts_time"]) for packet in packets if packet["stream_index"] == track]
            self.assertLessEqual(times[0], 0)
            self.assertTrue(0.9 < times[-1] < 1)

    def test_video_alpha_is_authored_as_three_distinct_opacities(self):
        for name, encoder, _, _ in VIDEO_ALPHA:
            with self.subTest(name=name):
                input_options = ["-c:v", encoder] if encoder.startswith("libvpx") else []
                alpha = subprocess.check_output(
                    [
                        "ffmpeg",
                        "-v",
                        "error",
                        *input_options,
                        "-i",
                        self.output / name,
                        "-frames:v",
                        "1",
                        "-vf",
                        "alphaextract",
                        "-pix_fmt",
                        "gray",
                        "-f",
                        "rawvideo",
                        "-",
                    ]
                )
                self.assertEqual(len(alpha), 96 * 64)
                self.assertEqual(alpha[32 * 96 + 16], 0)
                self.assertAlmostEqual(alpha[32 * 96 + 48], 128, delta=2)
                self.assertEqual(alpha[32 * 96 + 80], 255)

    def test_http_fixture_manifests_carry_video_and_audio(self):
        catalog = json.loads((self.output / MANIFEST).read_text())
        for entry in catalog["networkStreams"]:
            with self.subTest(file=entry["file"]):
                manifest = (self.output / entry["file"]).read_text()
                if entry["format"] == "dash":
                    self.assertEqual(manifest.count("<AdaptationSet "), 2)
                    video_init, video_first, _, _, audio_init, audio_first, *_ = entry["parts"]
                    (picture,) = self.probe_mp4_fragment(video_init, video_first)
                    (sound,) = self.probe_mp4_fragment(audio_init, audio_first)
                else:
                    self.assertIn("#EXT-X-ENDLIST", manifest)
                    for name in entry["parts"]:
                        self.assertIn(name, manifest)
                    picture, sound = self.probe(entry["file"])["streams"]
                self.assertEqual((picture["codec_name"], picture["width"], picture["height"]), ("h264", 176, 144))
                self.assertEqual((sound["codec_name"], sound["channels"], int(sound["sample_rate"])), ("aac", 1, 48000))

    def test_http_live_fixture_advances_its_window(self):
        stream = json.loads((self.output / MANIFEST).read_text())["liveStream"]
        initial = (self.output / stream["file"]).read_text().splitlines()
        update = (self.output / stream["update"]).read_text().splitlines()
        first, second, third = stream["parts"]
        self.assertIn("#EXT-X-MEDIA-SEQUENCE:101", initial)
        self.assertNotIn("#EXT-X-ENDLIST", initial)
        self.assertEqual([line for line in initial if not line.startswith("#")], [first, second])
        self.assertIn("#EXT-X-MEDIA-SEQUENCE:102", update)
        self.assertEqual(update[4:], ["#EXTINF:1,", second, "#EXT-X-DISCONTINUITY", "#EXTINF:1,", third, "#EXT-X-ENDLIST"])

    def test_long_hls_fixtures_distinguish_discontinuity_markers_from_clock_resets(self):
        catalog = json.loads((self.output / MANIFEST).read_text())
        for key in ("hlsDiscontinuities", "hlsTimestampResets"):
            with self.subTest(key=key):
                stream = catalog[key]
                playlist = (self.output / stream["file"]).read_text().splitlines()
                self.assertEqual(playlist.count("#EXT-X-DISCONTINUITY"), 2)
                self.assertIn("#EXT-X-ENDLIST", playlist)
                segments = [entry for entry in playlist if not entry.startswith("#")]
                self.assertEqual(len(segments), 9)
                expected = stream["parts"] if key == "hlsDiscontinuities" else stream["parts"] * 3
                self.assertEqual(segments, expected)
                starts = [float(self.first_frame(part)["best_effort_timestamp_time"]) for part in segments]
                for index, start in enumerate(starts):
                    expected_offset = index if key == "hlsDiscontinuities" else index % 3
                    self.assertAlmostEqual(start - starts[0], expected_offset, delta=0.08)

    def test_live_dash_fixture_appends_one_valid_media_fragment(self):
        stream = json.loads((self.output / MANIFEST).read_text())["liveDash"]
        init, *segments = stream["parts"]
        for key, expected in (("file", segments[:-1]), ("update", segments)):
            manifest = ElementTree.parse(self.output / stream[key]).getroot()
            self.assertEqual(manifest.get("type"), "dynamic")
            self.assertEqual(manifest.find(".//{*}Initialization").get("sourceURL"), init)
            self.assertEqual([node.get("media") for node in manifest.findall(".//{*}SegmentURL")], expected)
        for segment in segments:
            (picture,) = self.probe_mp4_fragment(init, segment)
            self.assertEqual((picture["codec_name"], picture["width"], picture["height"]), ("h264", 176, 144))

    def test_live_dash_rollover_fixtures_advance_both_tracks(self):
        stream = json.loads((self.output / MANIFEST).read_text())["dashRollovers"]
        for (start, end), filename in zip(((0, 2), (1, 4), (3, 6)), stream["manifests"], strict=True):
            manifest = ElementTree.parse(self.output / filename).getroot()
            self.assertEqual(manifest.get("type"), "dynamic")
            for adaptation in manifest.findall(".//{*}AdaptationSet"):
                kind = adaptation.get("contentType")
                codec = {"video": "h264", "audio": "aac"}[kind]
                init, *segments = stream[kind]
                listing = adaptation.find(".//{*}SegmentList")
                self.assertEqual(listing.get("startNumber"), str(31 + start))
                self.assertEqual(listing.find("{*}Initialization").get("sourceURL"), init)
                names = [node.get("media") for node in listing.findall("{*}SegmentURL")]
                self.assertEqual(names, segments[start:end])
                for second, name in enumerate(names, start=start):
                    (track,) = self.probe_mp4_fragment(init, name)
                    self.assertEqual(track["codec_name"], codec)
                    self.assertAlmostEqual(float(track["start_time"]), second, delta=0.08)

    def test_vobsub_index_opens_the_associated_dvd_bitmap(self):
        index = self.probe("subtitles-vobsub.idx")
        self.assertEqual(index["format"]["format_name"], "vobsub")
        (subtitle,) = index["streams"]
        self.assertEqual(subtitle["codec_name"], "dvd_subtitle")
        self.assertEqual((subtitle["width"], subtitle["height"]), (360, 640))

    def test_http_hls_master_exposes_both_rendition_resolutions(self):
        stream = json.loads((self.output / MANIFEST).read_text())["hlsRenditions"]
        manifest = (self.output / stream["file"]).read_text()
        playlists = [name for name in stream["parts"] if name.endswith(".m3u8")]
        self.assertEqual(len(playlists), 2)
        for playlist, width, height, bitrate in zip(playlists, (176, 352), (144, 288), (150000, 500000), strict=True):
            self.assertIn(f"BANDWIDTH={bitrate},RESOLUTION={width}x{height}\n{playlist}\n", manifest)
            picture, sound = self.probe(playlist)["streams"]
            self.assertEqual((picture["codec_name"], picture["width"], picture["height"]), ("h264", width, height))
            self.assertEqual((sound["codec_name"], int(sound["sample_rate"])), ("aac", 48000))

    def test_h264_sei_and_mov_caption_track_carry_the_same_cea608_cues(self):
        (track,) = self.probe(CEA608_TS)["streams"]
        self.assertEqual((track["codec_name"], track["r_frame_rate"]), ("h264", "30000/1001"))
        _, track = self.probe(CEA608_MOV)["streams"]
        self.assertEqual((track["codec_name"], track["codec_tag_string"]), ("eia_608", "c608"))
        scc = self.probe(CEA608_SCC)
        self.assertEqual(scc["format"]["format_name"], "scc")
        self.assertEqual(scc["streams"][0]["codec_name"], "eia_608")
        for source in (("-f", "lavfi", "-i", f"movie={CEA608_TS}[out+subcc]"), ("-i", CEA608_MOV)):
            with self.subTest(source=source):
                captions = subprocess.check_output(
                    ["ffmpeg", "-v", "error", *source, "-map", "0:s:0", "-f", "srt", "pipe:1"],
                    cwd=self.output,
                    text=True,
                )
                self.assertIn("00:00:01,268 --> 00:00:02,336", captions)
                self.assertIn("FIRST CAPTION", captions)
                self.assertIn("00:00:03,270 --> 00:00:04,338", captions)
                self.assertIn("SECOND CAPTION", captions)

    def test_caption_sidecars_preserve_both_cues(self):
        for name, format_name in ((CEA608_MCC, "mcc"), (CEA608_RCWT, "rcwt")):
            with self.subTest(format_name=format_name):
                probe = self.probe(name)
                self.assertEqual(probe["format"]["format_name"], format_name)
                self.assertEqual([stream["codec_name"] for stream in probe["streams"]], ["eia_608"])
                text = subprocess.check_output(
                    ["ffmpeg", "-v", "error", "-i", str(self.output / name), "-map", "0:s:0", "-f", "srt", "pipe:1"],
                    text=True,
                )
                self.assertEqual(len(text.strip().split("\n\n")), 2)
                self.assertRegex(text, r"00:00:01,26[78] --> 00:00:02,33[46]")
                self.assertRegex(text, r"00:00:03,(?:267|270) --> 00:00:04,33[48]")
                self.assertIn("FIRST CAPTION", text)
                self.assertIn("SECOND CAPTION", text)

    def test_generated_amr_uses_complete_fixed_rate_frames(self):
        for band, magic, size, header, rate in (
            ("nb", b"#!AMR\n", 32, 0x3C, 8000),
            ("wb", b"#!AMR-WB\n", 61, 0x44, 16000),
        ):
            with self.subTest(band=band):
                name = f"codecs-amr-{band}.amr"
                contents = (self.output / name).read_bytes()
                self.assertTrue(contents.startswith(magic))
                self.assertEqual(len(contents) - len(magic), 63 * size)
                self.assertEqual(set(contents[len(magic) :: size]), {header})
                (track,) = self.probe(name)["streams"]
                self.assertEqual((track["codec_name"], int(track["sample_rate"]), track["channels"]), (f"amr_{band}", rate, 1))

    def test_vc1_advanced_profile_decodes_both_colors_in_each_container(self):
        for name, muxer in ((VC1_STREAM, "vc1"), *VC1_CONTAINERS):
            with self.subTest(name=name):
                info = self.probe(name)
                self.assertIn(muxer, info["format"]["format_name"].split(","))
                (track,) = info["streams"]
                self.assertEqual(
                    (track["codec_name"], track["profile"], track["width"], track["height"]),
                    ("vc1", "Advanced", 32, 32),
                )
                rgb = subprocess.check_output(
                    [
                        "ffmpeg",
                        "-v",
                        "error",
                        "-xerror",
                        "-i",
                        str(self.output / name),
                        "-fps_mode",
                        "passthrough",
                        "-pix_fmt",
                        "rgb24",
                        "-f",
                        "rawvideo",
                        "pipe:1",
                    ]
                )
                pixels_per_color = 32 * 32 * 12
                self.assertEqual(len(rgb), pixels_per_color * 6)
                self.assertEqual(rgb, b"\xff\x00\x00" * pixels_per_color + b"\x00\x00\xff" * pixels_per_color)

    def test_vc1_main_profile_decodes_both_colors_in_each_container(self):
        for name, muxer in ((WMV3_STREAM, "vc1test"), *WMV3_CONTAINERS):
            with self.subTest(name=name):
                info = self.probe(name)
                self.assertIn(muxer, info["format"]["format_name"].split(","))
                (track,) = info["streams"]
                self.assertEqual(
                    (track["codec_name"], track["profile"], track["width"], track["height"]),
                    ("wmv3", "Main", 32, 32),
                )
                rgb = subprocess.check_output(
                    [
                        "ffmpeg",
                        "-v",
                        "error",
                        "-xerror",
                        "-i",
                        self.output / name,
                        "-fps_mode",
                        "passthrough",
                        "-pix_fmt",
                        "rgb24",
                        "-f",
                        "rawvideo",
                        "pipe:1",
                    ]
                )
                pixels_per_color = 32 * 32 * 12
                self.assertEqual(rgb, b"\xff\x00\x0f" * pixels_per_color + b"\x19\x00\xff" * pixels_per_color)

    def test_ape_fixture_preserves_the_source_and_has_multiple_compressed_frames(self):
        clip = json.loads((self.output / MANIFEST).read_text())["monkeysAudio"]
        path = str(self.output / clip["file"])
        info = self.probe(clip["file"])
        (track,) = info["streams"]
        self.assertEqual(info["format"]["format_name"], "ape")
        self.assertEqual((track["codec_name"], int(track["sample_rate"]), track["channels"]), ("ape", 48000, 1))
        pts = subprocess.check_output(["ffprobe", "-v", "error", "-show_entries", "packet=pts", "-of", "csv=p=0", path], text=True)
        starts = [int(value) for value in pts.splitlines()]
        self.assertEqual(len(starts), 3)
        self.assertGreater(clip["seekStartFrame"], starts[1])
        self.assertLess(clip["seekStartFrame"], starts[2])
        pcm = subprocess.check_output(["ffmpeg", "-v", "error", "-i", path, "-f", "s16le", "pipe:1"])
        self.assertEqual(len(pcm), clip["frames"] * 2)
        self.assertEqual(hashlib.sha256(pcm).hexdigest(), clip["sha256"])
        self.assertEqual(hashlib.sha256(pcm[clip["seekStartFrame"] * 2 :]).hexdigest(), clip["seekSha256"])
        self.assertEqual(hashlib.sha256(pcm[(clip["seekStartFrame"] - 1) * 2 :]).hexdigest(), clip["seekEarlySha256"])

    def test_datagrams_use_complete_transport_packets_and_a_constant_mux_rate(self):
        data = (self.output / DATAGRAM_TS).read_bytes()
        self.assertEqual(len(data) % 188, 0)
        self.assertEqual(set(data[::188]), {0x47})
        info = self.probe(DATAGRAM_TS)
        self.assertEqual([stream["codec_name"] for stream in info["streams"]], ["h264", "aac"])
        self.assertAlmostEqual(float(info["format"]["duration"]), 12, delta=0.2)
        self.assertAlmostEqual(int(info["format"]["bit_rate"]), 256_000, delta=3000)

    def test_mpeg_audio_adu_payload_uses_independent_constant_size_frames(self):
        data = (self.output / MP3_ADU).read_bytes()
        frame_size = 384
        self.assertEqual(len(data) % frame_size, 0)
        self.assertGreater(len(data) // frame_size, 80)
        for offset in range(0, len(data), frame_size):
            frame = data[offset : offset + frame_size]
            self.assertEqual(frame[:2], b"\xff\xfb")
            self.assertEqual(frame[2] & 0xFE, 0x94)  # 128 kb/s, 48 kHz, unpadded.
            self.assertEqual((frame[4] << 1) | (frame[5] >> 7), 0)  # main_data_begin.

    def test_dts_hd_reader_preserves_the_dts_core_payload(self):
        source = "codecs-dts-core.dts"
        target = "codecs-dts-hd-container.dtshd"
        info = self.probe(target)
        self.assertEqual(info["format"]["format_name"], "dtshd")
        self.assertEqual(info["streams"][0]["codec_name"], "dts")
        packet_data = subprocess.check_output(
            [
                "ffmpeg",
                "-v",
                "error",
                "-i",
                str(self.output / target),
                "-map",
                "0:a:0",
                "-c:a",
                "copy",
                "-f",
                "dts",
                "pipe:1",
            ]
        )
        self.assertEqual(packet_data, (self.output / source).read_bytes())

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

    def test_mp42_fixture_uses_microsoft_mpeg4_v2_in_asf(self):
        info = self.probe("video-mp42.asf")
        (video,) = info["streams"]
        self.assertEqual(info["format"]["format_name"], "asf")
        self.assertEqual((video["codec_name"], video["codec_tag_string"]), ("msmpeg4v2", "MP42"))

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

    def test_hdr_luma_bars_preserve_the_source_code_values(self):
        for name, transfer in [("color-hdr10-luma.mkv", "smpte2084"), ("color-hlg-luma.mkv", "arib-std-b67")]:
            with self.subTest(name=name):
                frame = self.first_frame(name)
                self.assertEqual((frame["color_range"], frame["color_transfer"], frame["pix_fmt"]), ("tv", transfer, "yuv420p10le"))
                for time, bars in [(0.5, [64, 300, 520, 740]), (2.25, [740, 520, 300, 64])]:
                    raw = subprocess.check_output(
                        [
                            "ffmpeg",
                            "-v",
                            "error",
                            "-ss",
                            str(time),
                            "-i",
                            str(self.output / name),
                            "-frames:v",
                            "1",
                            "-pix_fmt",
                            "yuv420p10le",
                            "-f",
                            "rawvideo",
                            "pipe:1",
                        ]
                    )
                    pixels = [(90 * 320 + x) * 2 for x in (40, 120, 200, 280)]
                    self.assertEqual([int.from_bytes(raw[i : i + 2], "little") for i in pixels], bars)

    def test_hdr10plus_authors_three_scenes_in_the_decoded_frames(self):
        filename = self.output / "color-hdr10plus-scenes.mkv"
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
                    "frame=pts_time:frame_side_data",
                    "-of",
                    "json",
                    filename,
                ]
            )
        )["frames"]
        self.assertEqual(len(frames), 36)
        averages = [1300, 2800, 1700]
        for index, frame in enumerate(frames):
            (scene,) = [
                entry for entry in frame["side_data_list"] if entry["side_data_type"] == "HDR Dynamic Metadata SMPTE2094-40 (HDR10+)"
            ]
            self.assertEqual(scene["num_windows"], 1)
            # FFprobe reports the raw target in 0.0001-nit increments.
            self.assertEqual(scene["targeted_system_display_maximum_luminance"], "10000000/1")
            self.assertEqual(scene["average_maxrgb"], f"{averages[index // 12]}/100000")
            self.assertAlmostEqual(float(frame["pts_time"]), index / 12, delta=0.001)

    def test_av1_film_grain_can_be_applied_or_omitted(self):
        (stream,) = self.probe(AV1_FILM_GRAIN)["streams"]
        self.assertEqual((stream["codec_name"], stream["profile"], stream["pix_fmt"]), ("av1", "Main", "yuv420p10le"))
        samples = [
            subprocess.check_output(
                [
                    "ffmpeg",
                    "-v",
                    "error",
                    "-c:v",
                    "libdav1d",
                    "-filmgrain",
                    grain,
                    "-i",
                    str(self.output / AV1_FILM_GRAIN),
                    "-frames:v",
                    "1",
                    "-pix_fmt",
                    "gray",
                    "-f",
                    "rawvideo",
                    "pipe:1",
                ]
            )
            for grain in ("0", "1")
        ]
        self.assertEqual(len(samples[0]), 160 * 96)
        self.assertEqual(len(samples[1]), len(samples[0]))
        different = sum(abs(a - b) > 1 for a, b in zip(*samples, strict=True))
        self.assertGreater(different, len(samples[0]) // 4)

    def test_dolby_vision_configuration_and_rpu_compression(self):
        rpu_bytes = {}
        for name, profile, compatibility, compression, transfer, rate in [
            ("dolby-vision-p5.mp4", 5, 0, "none", None, "120/1"),
            ("dolby-vision-p7.mp4", 7, 6, "none", "smpte2084", "120/1"),
            ("dolby-vision-p81.mp4", 8, 1, "none", "smpte2084", "120/1"),
            ("dolby-vision-p84.mp4", 8, 4, "none", "arib-std-b67", "24000/1001"),
            ("dolby-vision-p5-hls.m3u8", 5, 0, "none", None, "24000/1001"),
            ("dolby-vision-p81-hls.m3u8", 8, 1, "none", "smpte2084", "24000/1001"),
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
        for name in ("dolby-vision-p5.rpu", "dolby-vision-p7.rpu", "dolby-vision-p81.rpu"):
            with self.subTest(name=name):
                data = (self.output / name).read_bytes()
                self.assertEqual(data[0], 0x19)
                self.assertNotIn(b"\x00\x00\x00\x01", data)

    def test_profile7_invalid_base_has_inband_metadata_without_container_configuration(self):
        name = "dolby-vision-p7-invalid-base.mp4"
        video = self.probe(name)["streams"][0]
        self.assertEqual(video["color_transfer"], "arib-std-b67")
        self.assertFalse(any("dv_profile" in entry for entry in video.get("side_data_list", [])))
        self.assertTrue(any(entry["side_data_type"] == "Dolby Vision Metadata" for entry in self.first_frame(name)["side_data_list"]))

    def test_untagged_remux_preserves_video_packets_without_container_dolby_vision(self):
        for profile in ("p5", "p7", "p81", "p84"):
            name = f"dolby-vision-{profile}-untagged.mp4"
            with self.subTest(name=name):
                video = self.probe(name)["streams"][0]
                self.assertEqual(video["codec_tag_string"], "hvc1")
                self.assertFalse(any("dv_profile" in entry for entry in video.get("side_data_list", [])))
                metadata = self.first_frame(name)["side_data_list"]
                self.assertTrue(any(entry["side_data_type"] == "Dolby Vision Metadata" for entry in metadata))
                hashes = []
                for filename in (f"dolby-vision-{profile}.mp4", name):
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
                                "packet=data_hash",
                                "-show_data_hash",
                                "sha256",
                                "-of",
                                "json",
                                str(self.output / filename),
                            ]
                        )
                    )["packets"]
                    hashes.append([packet["data_hash"] for packet in packets])
                self.assertEqual(len(hashes[0]), 240)
                self.assertEqual(hashes[0], hashes[1])

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

    def test_standalone_audio_containers_and_codecs(self):
        for filename, codec, demuxer in [
            ("audio-flac.flac", "flac", "flac"),
            ("audio-alac.m4a", "alac", "mov"),
            ("audio-mp3.mp3", "mp3", "mp3"),
            ("audio-vorbis.ogg", "vorbis", "ogg"),
            ("audio-opus.ogg", "opus", "ogg"),
            ("audio-pcm.wav", "pcm_s16le", "wav"),
            ("audio-adts.aac", "aac", "aac"),
        ]:
            with self.subTest(filename=filename):
                info = self.probe(filename)
                (stream,) = info["streams"]
                self.assertIn(demuxer, info["format"]["format_name"].split(","))
                self.assertEqual((stream["codec_name"], stream["sample_rate"], stream["channels"]), (codec, "48000", 2))

    def test_high_efficiency_aac_profiles_and_wrappers(self):
        catalog = json.loads((self.output / MANIFEST).read_text())
        for clip in catalog["highEfficiencyAAC"]:
            with self.subTest(file=clip["file"]):
                info = self.probe(clip["file"])
                self.assertIn(clip["format"], info["format"]["format_name"].split(","))
                (stream,) = info["streams"]
                self.assertEqual(
                    (stream["codec_name"], stream["profile"], stream["sample_rate"], stream["channels"]),
                    ("aac", clip["profile"], "48000", 2),
                )

    def test_variable_bitrate_mp3_packets_have_different_sizes(self):
        sizes = json.loads(
            subprocess.check_output(
                [
                    "ffprobe",
                    "-v",
                    "error",
                    "-show_entries",
                    "packet=size",
                    "-of",
                    "json",
                    str(self.output / "codecs-mp3-vbr.mp3"),
                ]
            )
        )["packets"]
        self.assertGreater(len({entry["size"] for entry in sizes}), 2)

    def test_m4a_album_has_exact_chapter_bounds_and_embedded_art(self):
        info = self.probe("codecs-album.m4a")
        streams = {stream["codec_type"]: stream for stream in info["streams"]}
        self.assertEqual((streams["audio"]["codec_name"], streams["audio"]["duration_ts"]), ("aac", 147456))
        self.assertEqual(streams["video"]["codec_name"], "mjpeg")
        self.assertEqual(streams["video"]["disposition"]["attached_pic"], 1)
        self.assertEqual(
            [(chapter["start_time"], chapter["end_time"], chapter["tags"]["title"]) for chapter in info["chapters"]],
            [("0.000000", "1.024000", "Opening"), ("1.024000", "2.048000", "Middle"), ("2.048000", "3.072000", "Ending")],
        )
        self.assertEqual(info["format"]["tags"]["artist"], "Test ensemble")

    def test_eac3_bitrate_controls_are_six_channel_without_atmos(self):
        for bitrate in (256, 768):
            stream = self.probe(f"audio-eac3-{bitrate}k-5.1.mka")["streams"][0]
            self.assertEqual((stream["codec_name"], stream["channels"], stream["sample_rate"]), ("eac3", 6, "48000"))
            self.assertNotIn("Atmos", stream.get("profile", ""))

    def test_dts_track_switch_fixture(self):
        info = self.probe("audio-dts-multitrack.mkv")
        video, surround, stereo = info["streams"]
        self.assertEqual(video["codec_name"], "h264")
        for track, channels, default in [(surround, 6, 1), (stereo, 2, 0)]:
            self.assertEqual(
                (track["codec_name"], track["sample_rate"], track["channels"], track["disposition"]["default"]),
                ("dts", "48000", channels, default),
            )
        self.assertAlmostEqual(float(info["format"]["duration"]), 72, delta=0.05)

    def test_bluray_clips_contain_both_language_tracks_and_timed_pgs(self):
        for name in ("00001", "00002"):
            with self.subTest(clip=name):
                clip = self.output / "bluray" / "BDMV" / "STREAM" / f"{name}.m2ts"
                self.assertEqual(clip.stat().st_size % 192, 0)
                video, english, spanish, subtitle = self.probe(clip)["streams"]
                self.assertEqual((video["id"], video["codec_name"]), ("0x1011", "h264"))
                self.assertEqual((subtitle["id"], subtitle["codec_name"]), ("0x1200", "hdmv_pgs_subtitle"))
                for stream, identifier, language in ((english, "0x1100", "eng"), (spanish, "0x1101", "spa")):
                    self.assertEqual(
                        (stream["id"], stream["codec_name"], stream["channels"], stream["sample_rate"], stream["tags"]["language"]),
                        (identifier, "pcm_bluray", 2, "48000", language),
                    )
                packets = json.loads(
                    subprocess.check_output(
                        ["ffprobe", "-v", "error", "-select_streams", "s:0", "-show_entries", "packet=pts_time", "-of", "json", clip]
                    )
                )["packets"]
                self.assertEqual(len(packets), 7)
                self.assertAlmostEqual(float(packets[-1]["pts_time"]) - float(packets[0]["pts_time"]), 1, delta=0.001)

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

        xsub = self.probe("subtitles-xsub.avi")
        self.assertEqual(xsub["format"]["format_name"], "avi")
        self.assertEqual([track["codec_name"] for track in xsub["streams"]], ["mpeg4", "xsub"])
        mpl2 = self.probe("subtitles-cues.mpl2")
        self.assertEqual(mpl2["format"]["format_name"], "mpl2")
        self.assertEqual([track["codec_name"] for track in mpl2["streams"]], ["mpl2"])

    def test_zlib_matroska_tracks_match_uncompressed_packets(self):
        encoded = self.output / "subtitles-zlib.mkv"
        tracks = json.loads(subprocess.check_output(["mkvmerge", "-J", str(encoded)]))["tracks"]
        self.assertEqual([track["properties"]["content_encoding_algorithms"] for track in tracks[1:]], ["0", "0"])
        self.assertEqual([track["properties"]["codec_id"] for track in tracks[1:]], ["S_TEXT/ASS", "S_HDMV/PGS"])
        # Packet hashes are produced after container decompression. Equal hashes
        # prove that the fixture exercises compression without changing the cues.
        for index in (0, 1):
            packets = []
            for name in ("subtitles-none.mkv", "subtitles-zlib.mkv"):
                data = subprocess.check_output(
                    [
                        "ffprobe",
                        "-v",
                        "error",
                        "-select_streams",
                        f"s:{index}",
                        "-show_packets",
                        "-show_data_hash",
                        "sha256",
                        "-show_entries",
                        "packet=pts_time,data_hash",
                        "-of",
                        "json",
                        str(self.output / name),
                    ]
                )
                packets.append(json.loads(data)["packets"])
            self.assertGreater(len(packets[0]), 0)
            self.assertEqual(packets[0], packets[1])

    def test_images_decode_with_expected_frame_counts(self):
        for name, frames in [("image-webp-still.webp", 1), ("image-webp-animated.webp", 3)]:
            with self.subTest(name=name):
                header = (self.output / name).read_bytes()[:16]
                self.assertEqual((header[:4], header[8:12]), (b"RIFF", b"WEBP"))
                self.assertEqual((self.output / name).read_bytes().count(b"ANMF"), 0 if frames == 1 else frames)


if __name__ == "__main__":
    unittest.main()
