#!/usr/bin/env python3
"""Generate loopback TLS credentials and media for byte-range and encrypted input tests."""

import argparse
from pathlib import Path
import subprocess
import tempfile


def generate(output):
    output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="loopback-tls-") as temporary:
        key = Path(temporary) / "server.key"
        certificate = output / "tls-loopback.pem"
        subprocess.run(
            [
                "openssl",
                "req",
                "-new",
                "-x509",
                "-newkey",
                "rsa:2048",
                "-nodes",
                "-sha256",
                "-days",
                "3650",
                "-subj",
                "/CN=127.0.0.1",
                "-addext",
                "subjectAltName=IP:127.0.0.1",
                "-keyout",
                str(key),
                "-out",
                str(certificate),
            ],
            check=True,
            capture_output=True,
        )
        subprocess.run(
            [
                "openssl",
                "pkcs12",
                "-export",
                "-inkey",
                str(key),
                "-in",
                str(certificate),
                "-keypbe",
                "PBE-SHA1-3DES",
                "-certpbe",
                "PBE-SHA1-3DES",
                "-macalg",
                "sha1",
                "-passout",
                "pass:loopback-only",
                "-out",
                str(output / "tls-loopback.p12"),
            ],
            check=True,
        )

    inputs = [arg for color in ("red", "lime", "blue") for arg in ("-f", "lavfi", "-i", f"color={color}:s=176x144:r=12:d=1")]
    # Reserving space for the front index forces a byte seek beyond the HTTP read buffer.
    subprocess.run(
        [
            "ffmpeg",
            "-v",
            "error",
            "-nostdin",
            "-y",
            *inputs,
            "-filter_complex",
            "concat=n=3:v=1:a=0",
            "-c:v",
            "libx264",
            "-preset",
            "ultrafast",
            "-g",
            "12",
            "-moov_size",
            "4194304",
            str(output / "tls-ranges.mp4"),
        ],
        check=True,
    )
    # Use fixed, public fixture credentials to produce a reproducible AES-128 CBC source.
    subprocess.run(
        [
            "openssl",
            "enc",
            "-aes-128-cbc",
            "-K",
            "000102030405060708090a0b0c0d0e0f",
            "-iv",
            "101112131415161718191a1b1c1d1e1f",
            "-in",
            str(output / "tls-ranges.mp4"),
            "-out",
            str(output / "tls-ranges.mp4.enc"),
        ],
        check=True,
    )


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    generate(parser.parse_args().output)
