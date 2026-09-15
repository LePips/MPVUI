#!/usr/bin/env python3
"""Generate a synthetic identity-mapping Profile 5 RPU for native parser tests."""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile


def generate(output):
    output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="dovi-fixture-") as directory:
        work = Path(directory)
        config = {
            "cm_version": "V29", "profile": "5", "source_min_pq": 0, "source_max_pq": 3079,
            "level6": {"max_display_mastering_luminance": 1000, "min_display_mastering_luminance": 0,
                       "max_content_light_level": 1000, "max_frame_average_light_level": 200},
            "shots": [{"start": 0, "duration": 1, "metadata_blocks": [
                {"Level1": {"min_pq": 0, "max_pq": 3079, "avg_pq": 1500}},
            ]}],
        }
        (work / "metadata.json").write_text(json.dumps(config))
        subprocess.run(["dovi_tool", "generate", "-j", str(work / "metadata.json"),
                        "-o", str(work / "metadata.rpu")], check=True)
        data = (work / "metadata.rpu").read_bytes()
        if not data.startswith(b"\x00\x00\x00\x01\x19"):
            raise RuntimeError("Unexpected generated RPU NAL framing")
        # dovi_tool writes a start code followed by the RPU (without a HEVC
        # NAL header). FFmpeg's parser takes unescaped RBSP bytes.
        payload = data[4:].replace(b"\x00\x00\x03", b"\x00\x00")
        (output / "profile5.rpu").write_bytes(payload)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    generate(parser.parse_args().output)
