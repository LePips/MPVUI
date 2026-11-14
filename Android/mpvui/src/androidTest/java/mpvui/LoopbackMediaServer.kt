package mpvui

import java.io.Closeable
import java.io.IOException
import java.net.InetAddress
import java.net.Socket
import java.net.URI
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import javax.net.ServerSocketFactory
import javax.net.ssl.SSLServerSocket
import kotlin.concurrent.thread

internal class LoopbackMediaServer(
    resources: Map<String, ByteArray> = emptyMap(),
    private val hold: String? = null,
    socketFactory: ServerSocketFactory = ServerSocketFactory.getDefault(),
    private val authorization: String? = null,
    private val redirects: Map<String, String> = emptyMap(),
    private val cutoffs: Map<String, ResponseCutoff> = emptyMap(),
    private val versions: Map<String, List<ResourceVersion>> = emptyMap(),
    private val rawStream: ByteArray? = null,
    private val gopherSelector: String? = null,
) : Closeable {
    data class ResponseCutoff(val offset: Int, val resume: Boolean)
    data class ResourceVersion(val afterRequests: Set<String>, val bytes: ByteArray?)

    private val resources = ConcurrentHashMap(resources)
    private val server = socketFactory.createServerSocket(0, 10, InetAddress.getByName("127.0.0.1"))
    private val scheme = when {
        gopherSelector != null -> if (server is SSLServerSocket) "gophers" else "gopher"
        rawStream != null -> if (server is SSLServerSocket) "tls" else "tcp"
        else -> if (server is SSLServerSocket) "https" else "http"
    }
    private val requests = ConcurrentHashMap.newKeySet<String>()
    private val rangedRequests = ConcurrentHashMap<String, MutableSet<Int>>()
    private val requestPragmas = ConcurrentHashMap<String, MutableSet<String>>()
    private val failureResponses = ConcurrentHashMap.newKeySet<Int>()
    private val heldResponse = CountDownLatch(1)
    private val clients = ConcurrentHashMap.newKeySet<Socket>()
    private val responses = Executors.newCachedThreadPool { run ->
        Thread(run, "Playback fixture HTTP connection").apply { isDaemon = true }
    }
    private val worker = thread(name = "Playback fixture HTTP server", isDaemon = true) {
        while (!server.isClosed) {
            val socket = try {
                server.accept()
            } catch (_: IOException) {
                break
            }
            clients.add(socket)
            responses.execute {
                try {
                    socket.use(::respond)
                } catch (_: IOException) {
                    // The client may abandon an open response when it seeks or replaces the item.
                } finally {
                    clients.remove(socket)
                }
            }
        }
    }

    fun url(filename: String, userInfo: String? = null): String =
        URI(scheme, userInfo, "127.0.0.1", server.localPort, "/$filename", null, null).toASCIIString()

    fun requested(filename: String): Boolean = requests.contains(filename)

    fun requestedNonzeroRange(filename: String): Boolean = rangedRequests[filename]?.isNotEmpty() == true

    fun requestedRange(filename: String, startingAt: Int): Boolean = rangedRequests[filename]?.contains(startingAt) == true

    fun pragmas(filename: String): Set<String> = requestPragmas[filename]?.toSet().orEmpty()

    fun respondedWithError(status: Int): Boolean = failureResponses.contains(status)

    fun replace(filename: String, bytes: ByteArray) {
        resources[filename] = bytes
    }

    fun releaseHeldResponse() = heldResponse.countDown()

    override fun close() {
        releaseHeldResponse()
        server.close()
        worker.join(2500)
        clients.forEach { it.close() }
        responses.shutdown()
    }

    private fun respond(socket: Socket) {
        socket.soTimeout = 2000
        val output = socket.getOutputStream()
        if (rawStream != null) {
            if (gopherSelector != null) {
                if (socket.getInputStream().bufferedReader().readLine() != "/$gopherSelector") return
                requests.add(gopherSelector)
            }
            output.write(rawStream)
            return
        }

        val input = socket.getInputStream().bufferedReader()
        val request = input.readLine()?.split(' ') ?: return
        if (request.size != 3 || request[0] !in listOf("GET", "HEAD", "CONNECT")) return

        var range: String? = null
        var credentials: String? = null
        val pragmas = mutableListOf<String>()
        for (index in 0 until 100) {
            val line = input.readLine() ?: return
            if (line.isEmpty()) break
            if (line.startsWith("Range:", ignoreCase = true)) range = line.substringAfter(':').trim()
            if (line.startsWith("Authorization:", ignoreCase = true)) credentials = line.substringAfter(':').trim()
            if (line.startsWith("Pragma:", ignoreCase = true)) pragmas.add(line.substringAfter(':').trim())
        }
        if (request[0] == "CONNECT" && request[2] == "HTTP/1.1") {
            val transport = resources[request[1]] ?: return
            requests.add(request[1])
            output.write("HTTP/1.1 200 Connection Established\r\n\r\n".toByteArray())
            output.write(transport)
            return
        }

        val name = request[1].substringBefore('?').removePrefix("/")
        if (authorization != null && credentials != authorization) {
            failureResponses.add(401)
            output.write(("HTTP/1.1 401 Unauthorized\r\nWWW-Authenticate: Basic realm=\"Playback fixture\"\r\n" +
                "Content-Length: 0\r\nConnection: close\r\n\r\n").toByteArray())
            return
        }
        val target = redirects[name]
        if (target != null) {
            requests.add(name)
            output.write("HTTP/1.1 302 Found\r\nLocation: /$target\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".toByteArray())
            return
        }
        val version = versions[name]?.lastOrNull { requests.containsAll(it.afterRequests) }
        if (version != null && version.bytes == null) {
            failureResponses.add(410)
            output.write("HTTP/1.1 410 Gone\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".toByteArray())
            return
        }
        val body = version?.bytes ?: resources[name]
        if (body == null) {
            failureResponses.add(404)
            output.write("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".toByteArray())
            return
        }
        requests.add(name)
        if (pragmas.isNotEmpty()) requestPragmas.computeIfAbsent(name) { ConcurrentHashMap.newKeySet() }.addAll(pragmas)
        if (name == hold) heldResponse.await()

        val bytes = range?.let { byteRange(it, body.size) }
        if (bytes != null && bytes.first > 0) {
            rangedRequests.computeIfAbsent(name) { ConcurrentHashMap.newKeySet() }.add(bytes.first)
        }
        val status = when {
            range == null -> "200 OK"
            bytes != null -> "206 Partial Content"
            else -> "416 Range Not Satisfiable"
        }
        val contentType = when (name.substringAfterLast('.')) {
            "m3u8" -> "application/vnd.apple.mpegurl"
            "mpd" -> "application/dash+xml"
            "ts" -> "video/mp2t"
            "wmsp" -> "application/x-mms-framed"
            else -> "video/mp4"
        }
        val size = if (range == null) body.size else bytes?.count() ?: 0
        val header = buildString {
            append("HTTP/1.1 $status\r\n")
            append("Content-Type: $contentType\r\nAccept-Ranges: bytes\r\nContent-Length: $size\r\n")
            if (bytes != null) append("Content-Range: bytes ${bytes.first}-${bytes.last}/${body.size}\r\n")
            if (range != null && bytes == null) append("Content-Range: bytes */${body.size}\r\n")
            append("Connection: close\r\n\r\n")
        }
        output.write(header.toByteArray())
        if (request[0] == "GET" && size > 0) {
            val start = bytes?.first ?: 0
            // Keep the advertised length so the client observes a premature end of the response.
            val cutoff = cutoffs[name]
            val deliveredBytes = if (cutoff != null && (!cutoff.resume || start < cutoff.offset))
                (cutoff.offset - start).coerceIn(0, size) else size
            output.write(body, start, deliveredBytes)
        }
    }

    private fun byteRange(value: String, count: Int): IntRange? {
        if (!value.startsWith("bytes=") || count == 0) return null
        val bounds = value.removePrefix("bytes=").split('-')
        if (bounds.size != 2) return null
        if (bounds[0].isEmpty()) {
            val suffix = bounds[1].toIntOrNull()?.takeIf { it > 0 } ?: return null
            return (count - suffix).coerceAtLeast(0) until count
        }
        val start = bounds[0].toIntOrNull()?.takeIf { it in 0 until count } ?: return null
        val end = if (bounds[1].isEmpty()) count - 1 else bounds[1].toIntOrNull() ?: return null
        return (start..end.coerceAtMost(count - 1)).takeUnless { it.isEmpty() }
    }
}
