package mpvui

import android.system.ErrnoException
import android.system.Os
import android.system.OsConstants
import org.junit.Assume.assumeTrue
import java.io.Closeable
import java.io.IOException
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.net.InetSocketAddress
import java.nio.ByteBuffer
import java.util.concurrent.FutureTask
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.concurrent.thread

internal class LoopbackTransport private constructor(
    nextPacket: () -> ScheduledPacket?,
    private val media: String,
    private val payloadType: Int,
    private val sdpAttributes: List<String>,
) : Closeable {
    constructor(transport: ByteArray, usesRtp: Boolean) : this(
        MpegTransportPackets(transport).let { packets ->
            { ScheduledPacket(packets.next(usesRtp), MpegTransportPackets.INTERVAL_MS * 1000) }
        },
        "video", 33, listOf("a=rtpmap:33 MP2T/90000"),
    )

    constructor(audio: RtpAudioFixture, encoded: ByteArray) : this(
        RtpAudioPackets(encoded, audio).let { packets -> { ScheduledPacket(packets.next(), audio.packetMs * 1000) } },
        "audio", audio.payloadType, listOf("a=rtpmap:${audio.payloadType} ${audio.encoding}"),
    )

    constructor(fixture: RtpRecordingFixture, recording: ByteArray) : this(
        RtpRecordedPackets(recording, fixture.loopTicks).let { packets ->
            if (fixture.loopTicks == 0) packets::nextRecorded else packets::next
        },
        fixture.media, fixture.payloadType, fixture.sdpAttributes,
    )

    private val address = InetAddress.getByName("127.0.0.1")
    private val socket = DatagramSocket(0, address)
    val port = DatagramSocket(0, address).use { it.localPort }
    private val worker = thread(name = "Datagram transport fixture", isDaemon = true) {
        try {
            while (!socket.isClosed) {
                val (packet, delay) = nextPacket() ?: break
                socket.send(DatagramPacket(packet.array(), packet.position(), address, port))
                waitForNextPacket(delay)
            }
        } catch (error: IOException) {
            if (!socket.isClosed) throw error
        }
    }

    val sessionDescription: String
        get() = """
            v=0
            o=- 0 0 IN IP4 127.0.0.1
            s=Local transport stream
            c=IN IP4 127.0.0.1
            t=0 0
            m=$media $port RTP/AVP $payloadType
        """.trimIndent() + "\n" + sdpAttributes.joinToString("\n", postfix = "\n")

    fun withSapAnnouncement(play: (String) -> Unit) {
        val announcementPort = DatagramSocket(0, address).use { it.localPort }
        val origin = byteArrayOf(0x20, 0, 0, 1, 127, 0, 0, 1)
        val content = ("application/sdp\u0000" + sessionDescription.replace("\n", "\r\n")).encodeToByteArray()
        val announcement = origin + content
        val datagram = DatagramPacket(announcement, announcement.size, address, announcementPort)
        DatagramSocket(0, address).use { announcer ->
            val announce = thread(name = "SAP fixture", isDaemon = true) {
                try {
                    while (!announcer.isClosed) {
                        announcer.send(datagram)
                        Thread.sleep(50)
                    }
                } catch (error: IOException) {
                    if (!announcer.isClosed) throw error
                }
            }
            try {
                play("sap://127.0.0.1:$announcementPort")
            } finally {
                announcer.close()
                announce.join(1000)
            }
        }
    }

    override fun close() {
        socket.close()
        worker.join(1000)
    }

    companion object {
        fun withUdpLite(transport: ByteArray, play: (String) -> Unit) {
            val udpLiteProtocol = 136
            val endpoints = listOf(OsConstants.AF_INET to "127.0.0.1", OsConstants.AF_INET6 to "::1")
            val sender = endpoints.firstNotNullOfOrNull { (family, host) ->
                try {
                    Triple(family, host, Os.socket(family, OsConstants.SOCK_DGRAM, udpLiteProtocol))
                } catch (error: ErrnoException) {
                    if (error.errno != OsConstants.EAFNOSUPPORT && error.errno != OsConstants.EPROTONOSUPPORT) throw error
                    null
                }
            }
            assumeTrue("The kernel provides a UDP-Lite socket", sender != null)
            val (family, host, socket) = sender ?: return
            try {
                val address = InetAddress.getByName(host)
                val probe = Os.socket(family, OsConstants.SOCK_DGRAM, udpLiteProtocol)
                val port = try {
                    Os.bind(probe, address, 0)
                    (Os.getsockname(probe) as InetSocketAddress).port
                } finally {
                    Os.close(probe)
                }
                val running = AtomicBoolean(true)
                val packets = MpegTransportPackets(transport)
                val send = FutureTask {
                    while (running.get()) {
                        val packet = packets.next(usesRtp = false)
                        Os.sendto(socket, packet.array(), 0, packet.position(), 0, address, port)
                        Thread.sleep(MpegTransportPackets.INTERVAL_MS)
                    }
                }
                thread(name = "UDP-Lite transport fixture", isDaemon = true) { send.run() }
                try {
                    val urlHost = if (family == OsConstants.AF_INET6) "[$host]" else host
                    play("udplite://$urlHost:$port")
                } finally {
                    running.set(false)
                    send.get(2, TimeUnit.SECONDS)
                }
            } finally {
                Os.close(socket)
            }
        }

        fun mpegAudioAdu(encoded: ByteArray): LoopbackTransport {
            val packets = MpegAudioAduPackets(encoded)
            val type = MpegAudioAduPackets.PAYLOAD_TYPE
            return LoopbackTransport(
                { ScheduledPacket(packets.next(), MpegAudioAduPackets.INTERVAL_MS * 1000) },
                "audio", type, listOf("a=rtpmap:$type mpa-robust/90000"),
            )
        }
    }
}

internal data class RtpRecordingFixture(
    val file: String,
    val media: String,
    val codec: String,
    val decoder: String,
    val payloadType: Int,
    val sdpAttributes: List<String>,
    val loopTicks: Int,
    val direct: Boolean,
    val width: Int,
    val height: Int,
) {
    val readers: List<String> get() = when {
        loopTicks == 0 -> listOf("sdp")
        direct -> listOf("rtp", "sdp", "rtsp")
        else -> listOf("sdp", "rtsp")
    }
}

internal data class ScheduledPacket(val bytes: ByteBuffer, val delayMicros: Long)

internal class RtpRecordedPackets(recording: ByteArray, private val loopTicks: Int) {
    private val packets = mutableListOf<ScheduledPacket>()
    private var index = 0
    private var sequence = 0
    private var timestampOffset = 0

    init {
        val input = ByteBuffer.wrap(recording)
        while (input.hasRemaining()) {
            require(input.remaining() >= 6)
            val bytes = input.short.toInt() and 0xffff
            val delay = input.int.toLong() and 0xffffffffL
            require(bytes in 12..input.remaining())
            val payload = ByteArray(bytes)
            input.get(payload)
            packets.add(ScheduledPacket(ByteBuffer.wrap(payload).apply { position(capacity()) }, delay))
        }
        require(packets.isNotEmpty())
    }

    fun next(): ScheduledPacket {
        val packet = packets[index]
        val buffer = ByteBuffer.wrap(packet.bytes.array().clone())
        buffer.putShort(2, sequence++.toShort())
        buffer.putInt(4, buffer.getInt(4) + timestampOffset)
        buffer.position(buffer.capacity())
        index++
        if (index == packets.size) {
            index = 0
            timestampOffset += loopTicks
        }
        return ScheduledPacket(buffer, packet.delayMicros)
    }

    // SRTP authenticates packet headers, so replay each original packet once.
    fun nextRecorded(): ScheduledPacket? = if (index < packets.size) packets[index++] else null
}

internal fun waitForNextPacket(delayMicros: Long) {
    if (delayMicros > 0) Thread.sleep(delayMicros / 1000, (delayMicros % 1000).toInt() * 1000)
}

internal data class RtpAudioFixture(
    val payloadType: Int,
    val encoding: String,
    val packetBytes: Int,
    val packetTicks: Int,
    val packetMs: Long,
)

internal class RtpAudioPackets(private val encoded: ByteArray, private val format: RtpAudioFixture) {
    private val packet = ByteBuffer.allocate(12 + format.packetBytes)
    private var offset = 0
    private var sequence = 0
    private var timestamp = 0

    init {
        require(encoded.isNotEmpty() && encoded.size % format.packetBytes == 0)
    }

    fun next(): ByteBuffer {
        packet.clear()
        packet.putRtpHeader(format.payloadType, sequence, timestamp)
        packet.put(encoded, offset, format.packetBytes)
        offset = (offset + format.packetBytes) % encoded.size
        sequence++
        timestamp += format.packetTicks
        return packet
    }
}

internal class MpegTransportPackets(private val transport: ByteArray) {
    private val packet = ByteBuffer.allocate(12 + PACKET_SIZE)
    private var offset = 0
    private var sequence = 0
    private var timestamp = 0

    fun next(usesRtp: Boolean): ByteBuffer {
        val size = minOf(PACKET_SIZE, transport.size - offset)
        packet.clear()
        if (usesRtp) {
            packet.putRtpHeader(33, sequence, timestamp) // Static MPEG-TS payload type.
            sequence++
            timestamp += TICKS_PER_PACKET
        }
        packet.put(transport, offset, size)
        offset = (offset + size) % transport.size
        return packet
    }

    companion object {
        private const val PACKET_SIZE = 7 * 188
        private const val MUX_RATE = 256_000
        const val INTERVAL_MS = PACKET_SIZE * 8L * 1000 / MUX_RATE
        private const val TICKS_PER_PACKET = PACKET_SIZE * 8 * 90_000 / MUX_RATE
    }
}

private class MpegAudioAduPackets(private val encoded: ByteArray) {
    private val packet = ByteBuffer.allocate(12 + 2 + FRAME_SIZE)
    private var offset = 0
    private var sequence = 0
    private var timestamp = 0

    init {
        require(encoded.isNotEmpty() && encoded.size % FRAME_SIZE == 0)
    }

    fun next(): ByteBuffer {
        packet.clear()
        packet.putRtpHeader(PAYLOAD_TYPE, sequence, timestamp)
        // RFC 3119 uses a two-byte descriptor for a complete ADU of this size.
        packet.putShort((0x4000 or FRAME_SIZE).toShort())
        packet.put(encoded, offset, FRAME_SIZE)
        offset = (offset + FRAME_SIZE) % encoded.size
        sequence++
        timestamp += TICKS_PER_FRAME
        return packet
    }

    companion object {
        const val INTERVAL_MS = 24L
        const val PAYLOAD_TYPE = 96
        private const val FRAME_SIZE = 384
        private const val TICKS_PER_FRAME = 2160
    }
}

private fun ByteBuffer.putRtpHeader(payloadType: Int, sequence: Int, timestamp: Int) {
    put(0x80.toByte())
    put(payloadType.toByte())
    putShort(sequence.toShort())
    putInt(timestamp)
    putInt(0x4D505655)
}
