#!/usr/bin/env python3
"""Run a playback test with a local DTLS server carrying the authored MPEG-TS."""

import argparse
import errno
import socket
import subprocess
import tempfile
import threading
import time
from pathlib import Path

LOOPBACK = "127.0.0.1"


def udp_port():
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as probe:
        probe.bind((LOOPBACK, 0))
        return probe.getsockname()[1]


def wait_until_listening(server, port):
    deadline = time.monotonic() + 4
    while server.poll() is None and time.monotonic() < deadline:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as probe:
            try:
                probe.bind((LOOPBACK, port))
            except OSError as error:
                if error.errno != errno.EADDRINUSE:
                    raise
                return
        time.sleep(0.01)
    raise RuntimeError("OpenSSL did not bind its DTLS fixture socket")


def send_transport(server, media):
    for line in server.stderr:
        if b"write finished" in line:
            break
    else:
        return
    packet_size = 7 * 188
    try:
        while server.poll() is None:
            for offset in range(0, len(media), packet_size):
                server.stdin.write(media[offset : offset + packet_size])
                time.sleep(0.041)
    except BrokenPipeError:
        return


def run(assets, command):
    certificate = assets / "tls-loopback.pem"
    identity = assets / "tls-loopback.p12"
    media = (assets / "codecs-datagrams.ts").read_bytes()
    with tempfile.TemporaryDirectory(prefix="playback-dtls-") as directory:
        key = Path(directory) / "key.pem"
        subprocess.run(
            ["openssl", "pkcs12", "-in", identity, "-passin", "pass:loopback-only", "-nocerts", "-nodes", "-out", key],
            check=True,
        )
        port = udp_port()
        with subprocess.Popen(
            [
                "openssl",
                "s_server",
                "-quiet",
                "-state",
                "-dtls1_2",
                "-accept",
                f"{LOOPBACK}:{port}",
                "-cert",
                certificate,
                "-key",
                key,
                "-mtu",
                "1450",
            ],
            stdin=subprocess.PIPE,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            bufsize=0,
        ) as server:
            sender = threading.Thread(target=send_transport, args=(server, media))
            sender.start()
            try:
                wait_until_listening(server, port)
                arguments = [argument.replace("{port}", str(port)) for argument in command]
                return subprocess.run(arguments, check=False).returncode
            finally:
                server.terminate()
                try:
                    server.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    server.kill()
                    server.wait()
                sender.join()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--media", type=Path, default=Path(__file__).resolve().parents[2] / ".build/test-media")
    parser.add_argument("command", nargs=argparse.REMAINDER, help="Test command with {port} in its fixture argument")
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command or not any("{port}" in argument for argument in command):
        parser.error("Pass a test command with a {port} placeholder after --")
    return run(args.media, command)


if __name__ == "__main__":
    raise SystemExit(main())
