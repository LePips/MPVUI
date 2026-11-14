package mpvui

import java.io.ByteArrayOutputStream
import java.io.Closeable
import java.io.DataInputStream
import java.io.IOException
import java.io.OutputStream
import java.net.InetAddress
import java.net.Socket
import java.nio.ByteBuffer
import javax.net.ServerSocketFactory
import javax.net.ssl.SSLServerSocket
import kotlin.concurrent.thread

internal class LoopbackRtmpServer(
    recording: ByteArray,
    socketFactory: ServerSocketFactory,
    private val tunneled: Boolean = false,
    private val encrypted: Boolean = false,
) : Closeable {
    private val replies = readReplies(recording)
    private val listener = socketFactory.createServerSocket(0, 1, InetAddress.getByName("127.0.0.1"))
    private val lock = Any()
    private var client: Socket? = null
    private val suffix = when {
        encrypted -> "e"
        listener is SSLServerSocket -> "s"
        else -> ""
    }
    private val scheme = "rtmp" + (if (tunneled) "t" else "") + suffix
    val url = "$scheme://127.0.0.1:${listener.localPort}/app/fixture"
    private val worker = thread(name = "RTMP fixture", isDaemon = true) {
        while (!listener.isClosed) {
            val socket = try {
                listener.accept()
            } catch (_: IOException) {
                break
            }
            try {
                socket.use {
                    synchronized(lock) {
                        if (listener.isClosed) return@use
                        client = socket
                    }
                    socket.soTimeout = 4000
                    val input = DataInputStream(socket.getInputStream().buffered())
                    val output = socket.getOutputStream().buffered()
                    if (tunneled) serveTunnel(input, output) else serveRtmp(input, output)
                }
            } catch (_: IOException) {
                // The client may reject the fixture certificate or close the item.
            }
        }
    }

    private fun serveRtmp(input: DataInputStream, output: OutputStream) {
        val dialogue = Dialogue(replies, encrypted)
        val buffer = ByteArray(4096)
        while (true) {
            val length = input.read(buffer)
            if (length < 0) return
            val reply = dialogue.receive(buffer.copyOf(length)) ?: return
            if (reply.isNotEmpty()) {
                output.write(reply)
                output.flush()
            }
        }
    }

    private fun serveTunnel(input: DataInputStream, output: OutputStream) {
        val dialogue = Dialogue(replies, encrypted)
        var sequence: Int? = null
        while (true) {
            val request = readHeaderLine(input).split(' ')
            if (request.size != 3 || request[0] != "POST") return
            var length: Int? = null
            for (index in 0 until 32) {
                val header = readHeaderLine(input)
                if (header.isEmpty()) break
                if (header.startsWith("Content-Length:", ignoreCase = true)) {
                    length = header.substringAfter(':').trim().toIntOrNull()
                }
                if (index == 31) return
            }
            if (length == null || length !in 0..8192) return
            val body = ByteArray(length).also(input::readFully)
            val path = request[1]
            val reply = if (path == "/open/1" && sequence == null && body.contentEquals(POLL_INTERVAL)) {
                sequence = 0
                "fixture\n".toByteArray(Charsets.US_ASCII)
            } else {
                val fields = path.removePrefix("/").split('/')
                val current = sequence ?: return
                if (fields.size != 3 || fields[1] != "fixture" || fields[2].toIntOrNull() != current) return
                sequence = current + 1
                when (fields[0]) {
                    "send" -> POLL_INTERVAL + (dialogue.receive(body) ?: return)
                    "idle", "close" -> {
                        if (!body.contentEquals(POLL_INTERVAL)) return
                        POLL_INTERVAL
                    }
                    else -> return
                }
            }
            val header = "HTTP/1.1 200 OK\r\nContent-Type: application/x-fcs\r\nContent-Length: ${reply.size}\r\n\r\n"
            output.write(header.toByteArray(Charsets.US_ASCII))
            output.write(reply)
            output.flush()
            if (path.startsWith("/close/")) return
        }
    }

    private fun readHeaderLine(input: DataInputStream): String {
        val bytes = ByteArrayOutputStream()
        while (bytes.size() < 8192) {
            val character = input.readUnsignedByte()
            if (character == '\n'.code) return bytes.toString(Charsets.US_ASCII.name()).removeSuffix("\r")
            bytes.write(character)
        }
        throw IOException("RTMP tunnel header is too long")
    }

    override fun close() {
        synchronized(lock) {
            listener.close()
            client?.close()
        }
        worker.join(2500)
    }

    private class Dialogue(private val replies: List<ByteArray>, encrypted: Boolean) {
        private val cipher = if (encrypted) EncryptedRtmpHandshake() else null
        private var received = ByteArray(0)
        private var handshakeSent = false
        private var handshakeComplete = false
        private var step = 0

        fun receive(bytes: ByteArray): ByteArray? {
            if (step == replies.size) return ByteArray(0)
            received += if (handshakeComplete && cipher != null) cipher.decrypt(bytes) else bytes
            if (received.size > 8192) return null

            if (!handshakeSent) {
                if (received.size < HANDSHAKE_BYTES + 1) return ByteArray(0)
                val reply = if (cipher != null) {
                    cipher.reply(received.copyOfRange(0, HANDSHAKE_BYTES + 1)) ?: return null
                } else {
                    if (received[0].toInt() != 3) return null
                    byteArrayOf(3) + HANDSHAKE + received.copyOfRange(1, HANDSHAKE_BYTES + 1)
                }
                received = received.copyOfRange(HANDSHAKE_BYTES + 1, received.size)
                handshakeSent = true
                return reply
            }

            if (!handshakeComplete) {
                if (received.size < HANDSHAKE_BYTES) return ByteArray(0)
                val acknowledgment = received.copyOfRange(0, HANDSHAKE_BYTES)
                val verified = cipher?.accepts(acknowledgment) ?: acknowledgment.contentEquals(HANDSHAKE)
                if (!verified) return null
                received = received.copyOfRange(HANDSHAKE_BYTES, received.size)
                if (cipher != null) received = cipher.decrypt(received)
                handshakeComplete = true
            }

            val markerEnd = matchEnd(COMMANDS[step])
            if (markerEnd < 0 || step == COMMANDS.lastIndex && matchEnd(PLAYPATH, markerEnd) < 0) return ByteArray(0)
            received = ByteArray(0)
            val reply = replies[step++]
            return cipher?.encrypt(reply) ?: reply
        }

        private fun matchEnd(marker: ByteArray, start: Int = 0): Int {
            for (offset in start..(received.size - marker.size)) {
                if (marker.indices.all { received[offset + it] == marker[it] }) return offset + marker.size
            }
            return -1
        }
    }

    private fun readReplies(recording: ByteArray): List<ByteArray> {
        val buffer = ByteBuffer.wrap(recording)
        val replies = List(COMMANDS.size) {
            require(buffer.remaining() >= 4)
            val length = buffer.int
            require(length in 1..buffer.remaining())
            ByteArray(length).also(buffer::get)
        }
        require(!buffer.hasRemaining())
        return replies
    }

    private companion object {
        const val HANDSHAKE_BYTES = 1536
        val HANDSHAKE = ByteArray(HANDSHAKE_BYTES)
        val POLL_INTERVAL = byteArrayOf(0)

        fun amfString(value: String) = byteArrayOf(2, 0, value.length.toByte()) + value.toByteArray(Charsets.US_ASCII)

        fun amfNumber(value: Double) = ByteBuffer.allocate(9).put(0).putDouble(value).array()

        val COMMANDS = listOf(amfString("connect") + amfNumber(1.0), amfString("createStream") + amfNumber(2.0), amfString("play"))
        val PLAYPATH = amfString("fixture")
    }
}
