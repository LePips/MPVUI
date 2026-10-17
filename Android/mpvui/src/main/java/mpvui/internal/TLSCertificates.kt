package mpvui.internal

import android.content.Context
import android.util.AtomicFile
import android.util.Base64
import java.io.File
import java.security.KeyStore

/** Export the platform's system trust anchors for FFmpeg's native TLS backend. */
internal object TLSCertificates {
    private var cached: String? = null

    @Synchronized fun path(context: Context): String {
        cached?.takeIf { File(it).isFile }?.let { return it }
        val store = KeyStore.getInstance("AndroidCAStore").apply { load(null) }
        val certificates = store.aliases().toList().filter { it.startsWith("system:") }.map { alias ->
            val encoded = Base64.encodeToString(store.getCertificate(alias).encoded, Base64.NO_WRAP)
            "-----BEGIN CERTIFICATE-----\n" + encoded.chunked(64).joinToString("\n") + "\n-----END CERTIFICATE-----\n"
        }
        check(certificates.isNotEmpty()) { "Android system TLS trust store is empty" }
        val directory = File(context.cacheDir, "mpvui").apply { mkdirs() }
        val target = AtomicFile(File(directory, "system-ca.pem"))
        val output = target.startWrite()
        try {
            output.write(certificates.joinToString("").toByteArray(Charsets.US_ASCII))
            target.finishWrite(output)
        } catch (error: Exception) { target.failWrite(output); throw error }
        return target.baseFile.absolutePath.also { cached = it }
    }
}
