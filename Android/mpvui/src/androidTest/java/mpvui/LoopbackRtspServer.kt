package mpvui

import java.io.Closeable
import java.io.DataOutputStream
import java.io.IOException
import java.net.InetAddress
import java.net.Socket
import java.net.SocketException
import javax.net.ServerSocketFactory
import javax.net.ssl.SSLServerSocket
import kotlin.concurrent.thread

internal class LoopbackRtspServer private constructor(
    private val nextPacket: () -> ScheduledPacket,
    media: String,
    socketFactory: ServerSocketFactory = ServerSocketFactory.getDefault(),
) : Closeable {
    constructor(transport: ByteArray, socketFactory: ServerSocketFactory = ServerSocketFactory.getDefault()) : this(
        MpegTransportPackets(transport).let { packets ->
            { ScheduledPacket(packets.next(usesRtp = true), MpegTransportPackets.INTERVAL_MS * 1000) }
        },
        "video 0 RTP/AVP 33\r\na=rtpmap:33 MP2T/90000",
        socketFactory,
    )

    constructor(audio: RtpAudioFixture, encoded: ByteArray) : this(
        RtpAudioPackets(encoded, audio).let { packets -> { ScheduledPacket(packets.next(), audio.packetMs * 1000) } },
        "audio 0 RTP/AVP ${audio.payloadType}\r\na=rtpmap:${audio.payloadType} ${audio.encoding}",
    )

    constructor(fixture: RtpRecordingFixture, recording: ByteArray) : this(
        RtpRecordedPackets(recording, fixture.loopTicks)::next,
        (listOf("${fixture.media} 0 RTP/AVP ${fixture.payloadType}") + fixture.sdpAttributes).joinToString("\r\n"),
    )

    private val listener = socketFactory.createServerSocket(0, 1, InetAddress.getByName("127.0.0.1"))
    private val lock = Any()
    private var connection: Socket? = null
    @Volatile var playRequests = 0
        private set
    val url = "${if (listener is SSLServerSocket) "rtsps" else "rtsp"}://127.0.0.1:${listener.localPort}/source/"
    private val sessionDescription = """
        v=0
        o=- 0 0 IN IP4 127.0.0.1
        s=Local transport stream
        c=IN IP4 127.0.0.1
        t=0 0
        a=control:*
    """.trimIndent().replace("\n", "\r\n") + "\r\nm=$media\r\na=control:trackID=0\r\n"
    private val worker = thread(name = "RTSP transport stream fixture", isDaemon = true) {
        while (!listener.isClosed) {
            val client = try {
                listener.accept()
            } catch (_: SocketException) {
                break
            }
            try {
                client.use { socket ->
                    synchronized(lock) {
                        if (listener.isClosed) return@use
                        connection = socket
                    }
                    serve(socket)
                }
            } catch (_: IOException) {
                // The client or test closed this session. Keep accepting new sessions.
            } finally {
                synchronized(lock) { connection = null }
            }
        }
    }

    private fun serve(socket: Socket) {
        socket.tcpNoDelay = true
        val input = socket.getInputStream().bufferedReader(Charsets.US_ASCII)
        val output = DataOutputStream(socket.getOutputStream().buffered())
        while (!socket.isClosed) {
            val request = input.readLine()?.split(' ') ?: return
            if (request.size != 3) return
            val headers = mutableMapOf<String, String>()
            while (true) {
                val line = input.readLine() ?: return
                if (line.isEmpty()) break
                val name = line.substringBefore(':').lowercase()
                headers[name] = line.substringAfter(':').trim()
            }
            val cseq = headers["cseq"] ?: return
            var description = ""
            val responseHeaders = when (request[0]) {
                "OPTIONS" -> "Public: OPTIONS, DESCRIBE, SETUP, PLAY\r\n"
                "DESCRIBE" -> {
                    description = sessionDescription
                    "Content-Type: application/sdp\r\nContent-Base: ${request[1]}\r\n"
                }
                "SETUP" -> {
                    if (headers["transport"]?.contains("RTP/AVP/TCP") != true) return
                    "Session: 12345678\r\nTransport: RTP/AVP/TCP;unicast;interleaved=0-1\r\n"
                }
                "PLAY" -> {
                    if (headers["session"] != "12345678") return
                    playRequests++
                    "Session: 12345678\r\n"
                }
                else -> return
            }
            val response = "RTSP/1.0 200 OK\r\nCSeq: $cseq\r\n$responseHeaders" +
                "Content-Length: ${description.length}\r\n\r\n$description"
            output.write(response.toByteArray(Charsets.US_ASCII))
            output.flush()
            if (request[0] == "PLAY") break
        }

        while (!socket.isClosed) {
            val (packet, delay) = nextPacket()
            output.writeByte(0x24)
            output.writeByte(0) // RTP uses interleaved channel zero.
            output.writeShort(packet.position())
            output.write(packet.array(), 0, packet.position())
            output.flush()
            waitForNextPacket(delay)
        }
    }

    fun disconnect() {
        synchronized(lock) { connection?.close() }
    }

    override fun close() {
        synchronized(lock) {
            listener.close()
            connection?.close()
        }
        worker.join(1000)
    }
}
