package mpvui.internal

import android.content.Context
import mpvui.*

/** Mechanical conversion of public settings and platform paths into ABI v1 fields. */
internal fun PlayerConfiguration.coreRecord(context: Context): ByteArray {
    val quality = renderingQuality
    val cacheDirectory = java.io.File(context.cacheDir, "mpvui").apply { mkdirs() }
    val options = additionalOptions.toMutableMap()
    options.putIfAbsent("tls-ca-file", TLSCertificates.path(context))
    if (cacheDirectory.isDirectory) {
        options.putIfAbsent("gpu-shader-cache-dir", cacheDirectory.absolutePath)
        options.putIfAbsent("icc-cache-dir", cacheDirectory.absolutePath)
    }
    return CoreWire.encode(mapOf(
        "autoPlay" to autoPlay, "loop" to loop, "playbackRate" to playbackRate, "volume" to volume, "startTime" to startTime,
        "initialBufferSeconds" to initialBufferSeconds, "networkCacheSeconds" to networkCacheSeconds,
        "nativeVideoFeaturePolicy" to if (nativeVideoFeaturePolicy == NativeVideoFeaturePolicy.PREFER_FEATURES) "preferFeatures" else "preserveDolbyVision",
        "hdrPolicy" to hdrPolicy.name.lowercase(), "logLevel" to logLevel.mpvName,
        "additionalOptions" to options,
        "cache" to mapOf("mode" to cache.mode.mpvName, "maximumBytes" to cache.maximumBytes, "maximumBackBytes" to cache.maximumBackBytes),
        "deinterlace" to mapOf("mode" to deinterlace.mode.name.lowercase(), "algorithm" to deinterlace.algorithm.name.lowercase(),
            "fieldOrder" to deinterlace.fieldOrder.mpvName, "analyzeFieldOrder" to deinterlace.analyzeFieldOrder),
        "rendering" to mapOf(
            "preset" to if (quality.preset == RenderingQuality.Preset.HIGH_QUALITY) "highQuality" else quality.preset.name.lowercase(),
            "scaling" to quality.scaling?.mpvName, "chromaScaling" to quality.chromaScaling?.mpvName,
            "antiringing" to quality.antiringing, "chromaAntiringing" to quality.chromaAntiringing,
            "debanding" to quality.debanding, "dithering" to when (quality.dithering) {
                RenderingQuality.Dithering.AUTOMATIC -> "automatic"
                RenderingQuality.Dithering.DISABLED -> "disabled"
                else -> quality.dithering?.mpvName
            },
            "toneMapping" to quality.toneMapping?.mpvName, "gamutMapping" to quality.gamutMapping?.mpvName,
            "peakDetection" to quality.peakDetection?.mpvName, "shaders" to quality.shaders,
            "lut" to quality.lut?.let { mapOf("domain" to it.domain.mpvName, "path" to it.path) },
        ),
    ))
}

internal fun DisplayCapabilities.coreRecord(): ByteArray = CoreWire.encode(mapOf(
    "hdr10" to hdr10, "hlg" to hlg, "dolbyVision" to dolbyVision, "wideGamut" to wideGamut, "refreshRate" to refreshRate,
))
