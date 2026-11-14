package mpvui

import java.io.Closeable
import java.io.IOException
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import kotlin.concurrent.thread

internal class LoopbackFtpServer(private val media: ByteArray) : Closeable {
    private val address = InetAddress.getByName("127.0.0.1")
    private val server = ServerSocket(0, 4, address)
    private val controls = ConcurrentHashMap.newKeySet<Socket>()
    private val clients = Executors.newCachedThreadPool { work ->
        Thread(work, "FTP playback fixture client").apply { isDaemon = true }
    }
    @Volatile var restartedAtNonzeroOffset = false
        private set

    private val accept = thread(name = "FTP playback fixture", isDaemon = true) {
        while (!server.isClosed) {
            val control = try {
                server.accept()
            } catch (_: IOException) {
                break
            }
            controls.add(control)
            clients.execute {
                try {
                    control.use(::serve)
                } catch (_: IOException) {
                    // mpv can abandon a control connection when a load ends.
                } finally {
                    controls.remove(control)
                }
            }
        }
    }

    val url: String get() = "ftp://fixture:loopback@127.0.0.1:${server.localPort}/video.mp4"

    private fun serve(control: Socket) {
        val input = control.getInputStream().bufferedReader()
        val output = control.getOutputStream()
        fun reply(line: String) {
            synchronized(output) { output.write("$line\r\n".encodeToByteArray()) }
        }

        var passive: ServerSocket? = null
        var transfer: Socket? = null
        var offset = 0
        var userAccepted = false
        var authenticated = false
        try {
            reply("220 Playback fixture ready")
            while (true) {
                val line = input.readLine() ?: return
                val command = line.substringBefore(' ')
                val value = line.substringAfter(' ', missingDelimiterValue = "")
                when {
                    line == "USER fixture" -> {
                        userAccepted = true
                        reply("331 Password required")
                    }
                    userAccepted && line == "PASS loopback" -> {
                        authenticated = true
                        reply("230 Logged in")
                    }
                    !authenticated -> reply("530 Login required")
                    line == "TYPE I" -> reply("200 Binary")
                    line == "FEAT" -> reply("211 End")
                    line == "PWD" -> reply("257 \"/\"")
                    line == "SIZE /video.mp4" -> reply("213 ${media.size}")
                    line == "EPSV" -> {
                        passive?.close()
                        val listener = ServerSocket(0, 1, address).apply { soTimeout = 3000 }
                        passive = listener
                        reply("229 Entering Extended Passive Mode (|||${listener.localPort}|)")
                    }
                    command == "REST" -> {
                        val requested = value.toIntOrNull()
                        if (requested == null || requested !in 0..media.size) {
                            reply("501 Invalid offset")
                        } else {
                            offset = requested
                            if (offset > 0) restartedAtNonzeroOffset = true
                            reply("350 Restart accepted")
                        }
                    }
                    line == "RETR /video.mp4" -> {
                        val listener = passive
                        if (listener == null) {
                            reply("425 Open a passive data connection")
                            continue
                        }
                        val socket = listener.accept()
                        listener.close()
                        passive = null
                        transfer = socket
                        val start = offset
                        offset = 0
                        reply("150 Sending fixture")
                        clients.execute {
                            try {
                                socket.use { it.getOutputStream().write(media, start, media.size - start) }
                                reply("226 Transfer complete")
                            } catch (_: IOException) {
                                // A seek can cancel the active data transfer.
                            }
                        }
                    }
                    line == "ABOR" -> {
                        transfer?.close()
                        transfer = null
                        reply("226 Transfer aborted")
                    }
                    line == "QUIT" -> return
                    else -> reply("502 Unsupported fixture command")
                }
            }
        } finally {
            transfer?.close()
            passive?.close()
        }
    }

    override fun close() {
        server.close()
        accept.join(2500)
        controls.forEach { it.close() }
        clients.shutdownNow()
    }
}
