"""Loopback type 6 RTMP test fixture for the local player."""

import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import hmac
from pathlib import Path
import secrets
from socketserver import BaseRequestHandler, ThreadingTCPServer
import struct

HANDSHAKE_SIZE = 1536
DH_SIZE = 128
DH_PRIME = int(
    "FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD1"
    "29024E088A67CC74020BBEA63B139B22514A08798E3404DD"
    "EF9519B3CD3A431B302B0A6DF25F14374FE1356D6D51C245"
    "E485B576625E7EC6F44C42E9A637ED6B0BFF5CB6F406B7ED"
    "EE386BFB5A899FA5AE9F24117C4B1FE649286651ECE65381"
    "FFFFFFFFFFFFFFFF",
    16,
)
KEY_SUFFIX = bytes.fromhex("f0eec24a8068bee82e00d0d1029e7e576eec5d2d29806fab93b8e636cfeb31ae")
SERVER_KEY = b"Genuine Adobe Flash Media Server 001"
CLIENT_KEY = b"Genuine Adobe Flash Player 001"


def sign(key, data):
    return hmac.digest(key, data, "sha256")


def digest_offset(message):
    return 776 + sum(message[772:776]) % 728


def public_key_offset(message):
    return 8 + sum(message[768:772]) % 632


def amf_string(text):
    data = text.encode("ascii")
    return b"\x02" + len(data).to_bytes(2, "big") + data


COMMANDS = [
    amf_string("connect") + b"\x00" + struct.pack(">d", 1),
    amf_string("createStream") + b"\x00" + struct.pack(">d", 2),
    amf_string("play"),
]
PLAYPATH = amf_string("fixture")


def read_replies(asset):
    data = asset.read_bytes()
    replies = []
    for _ in COMMANDS:
        if len(data) < 4:
            raise ValueError("Missing fixture reply")
        size = int.from_bytes(data[:4], "big")
        if not 0 < size <= len(data) - 4:
            raise ValueError("Invalid fixture reply size")
        replies.append(data[4 : 4 + size])
        data = data[4 + size :]
    if data:
        raise ValueError("Unexpected fixture bytes")
    return replies


class RC4Stream:
    """Continuous media-protocol cipher streams after the 1536-byte discard."""

    def __init__(self, key):
        table = list(range(256))
        index = 0
        for left in range(256):
            index = (index + table[left] + key[left % len(key)]) & 255
            table[left], table[index] = table[index], table[left]
        self.table = table
        self.left = self.right = 0
        self.apply(bytes(HANDSHAKE_SIZE))

    def apply(self, data):
        table = self.table
        left, right = self.left, self.right
        output = bytearray()
        for byte in data:
            left = (left + 1) & 255
            right = (right + table[left]) & 255
            table[left], table[right] = table[right], table[left]
            output.append(byte ^ table[(table[left] + table[right]) & 255])
        self.left, self.right = left, right
        return bytes(output)


class Dialogue:
    def __init__(self, replies):
        self.replies = replies
        self.pending = b""
        self.created = False
        self.established = False
        self.step = 0

    def handshake(self, hello):
        if hello[0] != 6:
            raise ValueError("Expected the encrypted RTMP type")
        c1 = hello[1:]
        digest_at = digest_offset(c1)
        client_digest = c1[digest_at : digest_at + 32]
        if not hmac.compare_digest(client_digest, sign(CLIENT_KEY, c1[:digest_at] + c1[digest_at + 32 :])):
            raise ValueError("Invalid RTMP client handshake digest")
        key_at = public_key_offset(c1)
        client_key = c1[key_at : key_at + DH_SIZE]
        client_public = int.from_bytes(client_key, "big")
        if not 2 <= client_public < DH_PRIME - 1 or pow(client_public, (DH_PRIME - 1) // 2, DH_PRIME) != 1:
            raise ValueError("Invalid RTMP client key")

        private = secrets.randbelow(DH_PRIME - 3) + 2
        local_key = pow(2, private, DH_PRIME).to_bytes(DH_SIZE, "big")
        secret = pow(client_public, private, DH_PRIME).to_bytes(DH_SIZE, "big")
        self.decrypt = RC4Stream(sign(secret, local_key)[:16])
        self.encrypt = RC4Stream(sign(secret, client_key)[:16])
        s1 = bytearray(secrets.token_bytes(HANDSHAKE_SIZE))
        s1[:8] = bytes((0, 0, 0, 0, 9, 0, 0, 0))
        key_at = public_key_offset(s1)
        s1[key_at : key_at + DH_SIZE] = local_key
        digest_at = digest_offset(s1)
        local_digest = sign(SERVER_KEY, s1[:digest_at] + s1[digest_at + 32 :])
        s1[digest_at : digest_at + 32] = local_digest
        self.confirmation_key = sign(CLIENT_KEY + KEY_SUFFIX, local_digest)
        s2 = secrets.token_bytes(HANDSHAKE_SIZE - 32)
        confirmation = sign(sign(SERVER_KEY + KEY_SUFFIX, client_digest), s2)
        return b"\x06" + s1 + s2 + confirmation

    def receive(self, data):
        if self.step == len(self.replies):
            return b""
        self.pending += self.decrypt.apply(data) if self.established else data
        if len(self.pending) > 8192:
            raise ValueError("RTMP fixture input exceeded the command limit")
        if not self.created:
            if len(self.pending) < HANDSHAKE_SIZE + 1:
                return b""
            hello, self.pending = self.pending[: HANDSHAKE_SIZE + 1], self.pending[HANDSHAKE_SIZE + 1 :]
            self.created = True
            return self.handshake(hello)
        if not self.established:
            if len(self.pending) < HANDSHAKE_SIZE:
                return b""
            c2, following = self.pending[:HANDSHAKE_SIZE], self.pending[HANDSHAKE_SIZE:]
            if not hmac.compare_digest(c2[-32:], sign(self.confirmation_key, c2[:-32])):
                raise ValueError("Invalid RTMP client handshake confirmation")
            self.established = True
            self.pending = self.decrypt.apply(following)
        start = self.pending.find(COMMANDS[self.step])
        if start < 0 or (self.step == len(COMMANDS) - 1 and self.pending.find(PLAYPATH, start) < 0):
            return b""
        reply = self.replies[self.step]
        self.step += 1
        self.pending = b""
        return self.encrypt.apply(reply)


class RawFixture(BaseRequestHandler):
    def handle(self):
        dialogue = Dialogue(self.server.replies)
        self.request.settimeout(4)
        try:
            while data := self.request.recv(4096):
                self.request.sendall(dialogue.receive(data))
        except (OSError, ValueError):
            return


class TunnelFixture(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def setup(self):
        super().setup()
        self.connection.settimeout(4)

    def log_message(self, *_):
        pass

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        if not 0 < length <= 8192:
            self.send_error(400)
            return
        contents = self.rfile.read(length)
        if self.path == "/open/1" and contents == b"\x00":
            self.dialogue = Dialogue(self.server.replies)
            self.sequence = 0
            reply = b"fixture\n"
        else:
            fields = self.path.split("/")
            if len(fields) != 4 or fields[2:] != ["fixture", str(getattr(self, "sequence", None))]:
                self.send_error(404)
                return
            self.sequence += 1
            if fields[1] == "send":
                try:
                    reply = b"\x00" + self.dialogue.receive(contents)
                except ValueError:
                    self.send_error(400)
                    return
            elif fields[1] in {"idle", "close"} and contents == b"\x00":
                reply = b"\x00"
            else:
                self.send_error(404)
                return
        self.send_response(200)
        self.send_header("Content-Type", "application/x-fcs")
        self.send_header("Content-Length", str(len(reply)))
        self.end_headers()
        self.wfile.write(reply)


def make_server(asset, tunneled):
    if tunneled:
        server = ThreadingHTTPServer(("127.0.0.1", 0), TunnelFixture)
    else:
        server = ThreadingTCPServer(("127.0.0.1", 0), RawFixture)
        server.daemon_threads = True
    server.replies = read_replies(asset)
    return server


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("asset", type=Path)
    parser.add_argument("--tunneled", action="store_true")
    args = parser.parse_args()
    with make_server(args.asset, args.tunneled) as server:
        print(server.server_address[1], flush=True)
        server.serve_forever()


if __name__ == "__main__":
    main()
