"""Frame the authored FLV tags as RTMP server replies for local playback tests."""

import struct


FILENAME = "codecs-rtmp-replies.bin"
CHUNK_BYTES = 4096


def amf_string(value):
    encoded = value.encode()
    return b"\x02" + struct.pack(">H", len(encoded)) + encoded


def amf_number(value):
    return b"\x00" + struct.pack(">d", value)


def amf_object(**fields):
    content = bytearray(b"\x03")
    for name, value in fields.items():
        encoded = name.encode()
        content.extend(struct.pack(">H", len(encoded)) + encoded + value)
    return bytes(content) + b"\x00\x00\x09"


def message(channel, kind, content, *, timestamp=0, stream=0, chunk_bytes=CHUNK_BYTES):
    assert 2 <= channel <= 63 and timestamp < 0xFFFFFF and len(content) < 0xFFFFFF
    result = bytearray((channel,))
    result.extend(timestamp.to_bytes(3, "big"))
    result.extend(len(content).to_bytes(3, "big"))
    result.append(kind)
    result.extend(struct.pack("<I", stream))
    result.extend(content[:chunk_bytes])
    for offset in range(chunk_bytes, len(content), chunk_bytes):
        result.append(0xC0 | channel)
        result.extend(content[offset : offset + chunk_bytes])
    return result


def media_messages(flv):
    assert flv[:3] == b"FLV"
    location = int.from_bytes(flv[5:9], "big") + 4
    channels = {8: 4, 9: 6, 18: 5}
    result = bytearray()
    while location + 11 <= len(flv):
        kind = flv[location]
        length = int.from_bytes(flv[location + 1 : location + 4], "big")
        timestamp = int.from_bytes(flv[location + 4 : location + 7], "big") | (flv[location + 7] << 24)
        end = location + 11 + length
        assert end + 4 <= len(flv)
        assert int.from_bytes(flv[end : end + 4], "big") == length + 11
        result.extend(message(channels[kind], kind, flv[location + 11 : end], timestamp=timestamp, stream=1))
        location = end + 4
    assert location == len(flv)
    return result


def write_rtmp_replies(output, flv):
    connect = message(2, 1, struct.pack(">I", CHUNK_BYTES), chunk_bytes=128)
    connect.extend(
        message(
            3,
            20,
            amf_string("_result")
            + amf_number(1)
            + amf_object(fmsVer=amf_string("Playback fixture"), capabilities=amf_number(31))
            + amf_object(level=amf_string("status"), code=amf_string("NetConnection.Connect.Success")),
        )
    )
    create = message(3, 20, amf_string("_result") + amf_number(2) + b"\x05" + amf_number(1))
    play = message(2, 4, struct.pack(">HI", 0, 1))
    play.extend(
        message(
            5,
            20,
            amf_string("onStatus")
            + amf_number(0)
            + b"\x05"
            + amf_object(level=amf_string("status"), code=amf_string("NetStream.Play.Start")),
            stream=1,
        )
    )
    play.extend(media_messages(flv))
    # The harness consumes the replies in connect, createStream, play order.
    with (output / FILENAME).open("wb") as fixture:
        for reply in (connect, create, play):
            fixture.write(struct.pack(">I", len(reply)))
            fixture.write(reply)
