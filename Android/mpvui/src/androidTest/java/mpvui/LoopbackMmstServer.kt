package mpvui

import java.io.Closeable
import java.io.DataInputStream
import java.io.IOException
import java.io.OutputStream
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.concurrent.thread

internal class LoopbackMmstServer(wmsp: ByteArray) : Closeable {
    private val chunks = asfChunks(wmsp)
    private val listener = ServerSocket(0, 1, InetAddress.getByName("127.0.0.1"))
    private val lock = Any()
    private var client: Socket? = null
    val url = "mmst://127.0.0.1:${listener.localPort}/$FILENAME"
    private val worker = thread(name = "Windows Media TCP fixture", isDaemon = true) {
        try {
            listener.accept().use { socket ->
                synchronized(lock) {
                    if (listener.isClosed) return@use
                    client = socket
                }
                serve(socket)
            }
        } catch (_: IOException) {
            // The client or test closed the socket.
        }
    }

    private fun serve(socket: Socket) {
        val input = DataInputStream(socket.getInputStream().buffered())
        val output = socket.getOutputStream().buffered()
        for ((step, pair) in COMMANDS.withIndex()) {
            val (request, reply) = pair
            val header = littleEndian(ByteArray(12).also(input::readFully))
            val length = header.getInt(8) + 4
            if (header.getInt(4) != COMMAND_MARKER || length !in 28..4084) return
            val body = ByteArray(length).also(input::readFully)
            val command = littleEndian(body)
            if (command.getShort(24).toInt() != request) return
            if (request == 0x05 && (length < 44 || body.decodeToStringUtf16(44) != FILENAME)) return
            if (request == 0x33 && (length < 32 || command.getInt(28) != 2)) return
            val response = ByteBuffer.allocate(48).order(ByteOrder.LITTLE_ENDIAN)
            for (word in intArrayOf(1, COMMAND_MARKER, 32, 0x20534d4d, 4, step, 0, 0, 2, 0x40000 or reply, 0, 0)) {
                response.putInt(word)
            }
            output.write(response.array())
            if (request == 0x15) sendPacket(output, chunks.first(), id = 2, flags = 8, sequence = 0)
            if (request == 0x07) {
                if (length < 60) return
                val id = command.getInt(56)
                if (id !in 0..255) return
                for (index in 1 until chunks.size) {
                    sendPacket(output, chunks[index], id = id, flags = 0, sequence = index)
                }
            }
            output.flush()
        }
        socket.shutdownOutput()
        // Keep receiving until mpv closes the item.
        input.read()
    }

    override fun close() {
        synchronized(lock) {
            listener.close()
            client?.close()
        }
        worker.join(2500)
    }

    private fun ByteArray.decodeToStringUtf16(offset: Int) =
        String(this, offset, size - offset, Charsets.UTF_16LE).trimEnd('\u0000')

    private fun sendPacket(output: OutputStream, data: ByteArray, id: Int, flags: Int, sequence: Int) {
        val header = ByteBuffer.allocate(8).order(ByteOrder.LITTLE_ENDIAN)
            .putInt(sequence).put(id.toByte()).put(flags.toByte()).putShort((data.size + 8).toShort())
        output.write(header.array())
        output.write(data)
    }

    private fun asfChunks(wmsp: ByteArray): List<ByteArray> {
        val source = littleEndian(wmsp)
        val chunks = mutableListOf<ByteArray>()
        var offset = 0
        while (offset + 12 <= wmsp.size) {
            val kind = source.getShort(offset).toInt()
            if (kind == 0x4524) break
            val length = source.getShort(offset + 2).toInt() and 0xffff
            val end = offset + 4 + length
            require(kind == (if (chunks.isEmpty()) 0x4824 else 0x4424) && length >= 8 && end <= wmsp.size)
            chunks.add(wmsp.copyOfRange(offset + 12, end))
            offset = end
        }
        require(chunks.size > 1)
        return chunks
    }

    private fun littleEndian(bytes: ByteArray): ByteBuffer = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)

    private companion object {
        const val FILENAME = "fixture.asf"
        val COMMAND_MARKER = 0xb00bface.toInt()
        val COMMANDS = listOf(0x01 to 0x01, 0x18 to 0x15, 0x02 to 0x02, 0x05 to 0x06, 0x15 to 0x11, 0x33 to 0x21, 0x07 to 0x05)
    }
}
