"""Exact local remux cases that share the codec playback fixtures."""

# Repackage the same bytes when a reader accepts bitstreams from another authored fixture.
ADDITIONAL_REMUX_SOURCES = {
    ("asf", "asf", "asf"): {
        "android": (
            "012v.avi aasc.avi agm.avi aura.avi cyuv.avi dv-audio-pal.wav dxtory.avi fraps.avi ftr-voice.avi "
            "g729.wav hymt.avi kelvin.wav m101-8bit.avi mscc.avi mszh.avi mvha.avi notchlc.avi prosumer.avi "
            "rasc.avi rtv1.avi sc4.avi speex-nb.spx srgc.avi vble.avi vmix.avi wcmv.avi wnv1.avi zerocodec.avi"
        ),
        "both": "intel-h263.avi msmpeg4v1.avi",
    },
    ("avi", "avi", "avi"): {
        "android": "g729.wav kelvin.wav speex-nb.spx",
        "both": "hevc-yuv420p12le.mp4",
    },
    ("flv", "flv", "flv"): {
        "android": "speex-wb.spx",
        "both": "h263.avi mpeg4.avi",
    },
    ("live_flv", "flv", "flv"): {
        "android": "flashsv.flv flashsv2.flv nellymoser.flv speex-wb.spx",
        "both": "h263.avi mpeg4.avi pcm-s16le.flv pcm-u8.flv",
    },
    ("gxf", "gxf", "gxf"): {
        "android": "dv.dv pcm-s16le.caf",
    },
    ("ivf", "ivf", "ivf"): {
        "android": "ffv1-level1.mkv raw-i420.avi",
    },
    ("mov", "mov", "mov"): {
        "android": "dv.dv filmstrip.flm notchlc.avi speex-nb.spx",
    },
    ("nut", "nut", "nut"): {
        "android": (
            "012v.avi adpcm-ms.boa agm.avi aura.avi cyuv.avi dv-audio-pal.wav dxtory.avi fraps.avi ftr-voice.avi "
            "hymt.avi intel-h263.avi kelvin.wav m101-8bit.avi mp42.avi mpeg1.mpg msmpeg4v1.avi mszh.avi mvha.avi "
            "notchlc.avi prosumer.avi rasc.avi rtv1.avi sc4.avi vble.avi vmix.avi wnv1.avi zerocodec.avi"
        ),
    },
    ("sox", "sox", "sox"): {
        "android": "pcm-s32be.aiff",
    },
    ("w64", "w64", "w64"): {
        "android": "aac-lc.aac dv-audio-pal.wav ftr-voice.avi kelvin.wav speex-uwb.spx",
    },
    ("wav", "wav", "wav"): {
        "android": "ftr-voice.avi sc4.avi speex-nb.spx",
        "both": "aac-lc.aac",
    },
}


# Use explicit inputs so adding another encoder preset leaves these cases reproducible.
REMUX_SOURCES = {
    "012v": ("012v.avi", "colorVideo"),
    "aac": ("aac-lc.m4a", "audio"),
    "aac_latm": ("aac.loas", "audio"),
    "ac3": ("ac3.ac3", "audio"),
    "adpcm_g722": ("g722.wav", "audio"),
    "adpcm_g726": ("g726.wav", "audio"),
    "adpcm_ct": ("adpcm-ct.wav", "audio"),
    "adpcm_ima_dk3": ("adpcm-ima-dk3.wav", "audio"),
    "adpcm_ima_dk4": ("adpcm-ima-dk4.wav", "audio"),
    "adpcm_ima_oki": ("adpcm-ima-oki.wav", "audio"),
    "adpcm_ima_qt": ("ima-qt.mov", "audio"),
    "adpcm_ima_wav": ("ima-wav.wav", "audio"),
    "adpcm_ima_xbox": ("adpcm-ima-xbox.wav", "audio"),
    "adpcm_ms": ("adpcm-ms.wav", "audio"),
    "adpcm_sanyo": ("adpcm-sanyo.wav", "audio"),
    "adpcm_swf": ("adpcm-swf.flv", "audio"),
    "adpcm_yamaha": ("adpcm-yamaha.wav", "audio"),
    "adpcm_zork": ("adpcm-zork.wav", "audio"),
    "alac": ("alac.caf", "audio"),
    "amr_nb": ("amr-nb.amr", "audio"),
    "amr_wb": ("amr-wb.amr", "audio"),
    "amv": ("amv.avi", "video"),
    "asv1": ("asv1.avi", "video"),
    "asv2": ("asv2.avi", "video"),
    "aura": ("aura.avi", "colorVideo"),
    "av1": ("av1.mkv", "video"),
    "cfhd": ("cfhd.mov", "video"),
    "cinepak": ("cinepak.avi", "video"),
    "cljr": ("cljr.avi", "video"),
    "cyuv": ("cyuv.avi", "colorVideo"),
    "dirac": ("dirac.ts", "video"),
    "dnxhd": ("dnxhr.mxf", "video"),
    "dpx": ("dpx.mov", "video"),
    "dts": ("dts-core.dts", "audio"),
    "dvvideo": ("dv.dv", "video"),
    "dxtory": ("dxtory.avi", "colorVideo"),
    "eac3": ("eac3.eac3", "audio"),
    "ffv1": ("ffv1.mkv", "video"),
    "ffvhuff": ("ffvhuff.avi", "video"),
    "flac": ("flac.flac", "audio"),
    "flashsv": ("flashsv.flv", "video"),
    "flv1": ("spark.flv", "video"),
    "fraps": ("fraps.avi", "colorVideo"),
    "g723_1": ("g723.g723_1", "audio"),
    "gif": ("gif.gif", "video"),
    "gsm": ("telephone.gsm", "audio"),
    "gsm_ms": ("telephone-ms.wav", "audio"),
    "h261": ("h261.h261", "video"),
    "h263": ("h263.avi", "video"),
    "h263i": ("intel-h263.avi", "colorVideo"),
    "h264": ("h264.h264", "video"),
    "hevc": ("hevc.hevc", "video"),
    "huffyuv": ("huffyuv.avi", "video"),
    "ilbc": ("narrowband.ilbc", "audio"),
    "jpeg2000": ("jpeg2000.mov", "video"),
    "jpegls": ("jpegls.avi", "video"),
    "magicyuv": ("magicyuv.avi", "video"),
    "mjpeg": ("mjpeg.avi", "video"),
    "mlp": ("mlp.mlp", "audio"),
    "mp1": ("mpeg-layer1.mp1", "audio"),
    "mp2": ("mp2-fixed.mp2", "audio"),
    "mp3": ("mp3-fixed.mp3", "audio"),
    "mpeg1video": ("mpeg1.mpg", "video"),
    "mpeg2video": ("mpeg2.mpg", "video"),
    "mpeg4": ("mpeg4.avi", "video"),
    "msmpeg4v1": ("msmpeg4v1.avi", "colorVideo"),
    "msmpeg4v2": ("mp42.avi", "video"),
    "msmpeg4v3": ("mp43.avi", "video"),
    "msrle": ("msrle.avi", "video"),
    "msvideo1": ("msvideo1.avi", "video"),
    "mvha": ("mvha.avi", "colorVideo"),
    "nellymoser": ("nellymoser.flv", "audio"),
    "notchlc": ("notchlc.avi", "colorVideo"),
    "opus": ("opus.ogg", "audio"),
    "pcm_alaw": ("alaw.wav", "audio"),
    "pcm_f32be": ("pcm-f32be.aifc", "audio"),
    "pcm_f32le": ("pcm-f32le.caf", "audio"),
    "pcm_f64be": ("pcm-f64be.aifc", "audio"),
    "pcm_f64le": ("pcm-f64le.wav", "audio"),
    "pcm_mulaw": ("mulaw.wav", "audio"),
    "pcm_s16be": ("pcm-s16be.aiff", "audio"),
    "pcm_s16be_planar": ("s16be-planar.ast", "audio"),
    "pcm_s16le": ("pcm-s16le.caf", "audio"),
    "pcm_s24be": ("pcm-s24be.aiff", "audio"),
    "pcm_s24le": ("pcm-s24le.wav", "audio"),
    "pcm_s32be": ("pcm-s32be.aiff", "audio"),
    "pcm_s32le": ("pcm-s32le.wav", "audio"),
    "pcm_s64le": ("pcm-s64le.wav", "audio"),
    "pcm_s8": ("pcm-s8.aiff", "audio"),
    "pcm_u16le": ("sample-dump-u16.sdx", "audio"),
    "pcm_u24le": ("sample-dump-u24.sdx", "audio"),
    "pcm_u32le": ("sample-dump-u32.sdx", "audio"),
    "pcm_u8": ("pcm-u8.wav", "audio"),
    "png": ("png.mov", "video"),
    "prores": ("prores.mov", "video"),
    "prosumer": ("prosumer.avi", "colorVideo"),
    "r10k": ("r10k.mov", "video"),
    "r210": ("r210.mov", "video"),
    "ra_144": ("ra144.rm", "audio"),
    "rasc": ("rasc.avi", "colorVideo"),
    "rawvideo": ("rawvideo.y4m", "video"),
    "rpza": ("rpza.mov", "video"),
    "rtv1": ("rtv1.avi", "colorVideo"),
    "snow": ("snow.avi", "video"),
    "speedhq": ("speedhq.avi", "video"),
    "svq1": ("svq1.mov", "video"),
    "targa": ("targa.mov", "video"),
    "truehd": ("truehd.mka", "audio"),
    "tscc": ("tscc.avi", "video"),
    "utvideo": ("utvideo.avi", "video"),
    "v210": ("v210.mov", "video"),
    "vble": ("vble.avi", "colorVideo"),
    "vmix": ("vmix.avi", "colorVideo"),
    "vorbis": ("vorbis.ogg", "audio"),
    "vp8": ("vp8.webm", "video"),
    "vp9": ("vp9.webm", "video"),
    "wavpack": ("wavpack.wv", "audio"),
    "wmav1": ("wma1.asf", "audio"),
    "wmav2": ("wma2.asf", "audio"),
    "wmv1": ("wmv1.asf", "video"),
    "wmv2": ("wmv2.asf", "video"),
    "wnv1": ("wnv1.avi", "colorVideo"),
    "y41p": ("y41p.avi", "video"),
    "yuv4": ("yuv4.mov", "video"),
    "zlib": ("zlib.avi", "video"),
    "zmbv": ("zmbv.avi", "video"),
}

# libavformat's IVF reader also accepts these RIFF video tags. FFmpeg's IVF
# muxer writes only its standard codecs, so the generator wraps the packets.
IVF_PACKET_TAGS = {
    "012v": "012v",
    "amv": "AMVF",
    "aura": "AURA",
    "cfhd": "CFHD",
    "cinepak": "cvid",
    "cljr": "CLJR",
    "cyuv": "CYUV",
    "dirac": "drac",
    "dpx": "dpx ",
    "dvvideo": "dvsd",
    "dxtory": "xtor",
    "ffv1": "FFV1",
    "flashsv": "FSV1",
    "flv1": "FLV1",
    "fraps": "FPS1",
    "h261": "H261",
    "h263": "H263",
    "h263i": "I263",
    "h264": "H264",
    "jpeg2000": "mjp2",
    "jpegls": "MJLS",
    "magicyuv": "MAGY",
    "mjpeg": "MJPG",
    "mpeg1video": "mpg1",
    "mpeg2video": "mpg2",
    "mpeg4": "FMP4",
    "msmpeg4v1": "MPG4",
    "msmpeg4v2": "MP42",
    "msmpeg4v3": "MP43",
    "msvideo1": "MSVC",
    "mvha": "MVHA",
    "notchlc": "nlc1",
    "png": "MPNG",
    "prosumer": "BT20",
    "r10k": "R10k",
    "r210": "r210",
    "rasc": "RASC",
    "rawvideo": "I420",
    "rpza": "azpr",
    "rtv1": "RTV1",
    "snow": "SNOW",
    "speedhq": "SHQ0",
    "svq1": "svq1",
    "targa": "tga ",
    "v210": "v210",
    "vble": "VBLE",
    "vmix": "VMX1",
    "wmv1": "WMV1",
    "wnv1": "WNV1",
    "y41p": "Y41P",
    "yuv4": "yuv4",
    "zmbv": "ZMBV",
}

# (reader, muxer, suffix) -> codec IDs. Android has additional FFmpeg readers and decoders.
REMUX_MAPPINGS = {
    ("aiff", "aiff", "aiff"): {
        "both": ("adpcm_g722 pcm_alaw pcm_mulaw pcm_s16le pcm_u8"),
    },
    ("asf", "asf", "asf"): {
        "both": (
            "aac aac_latm ac3 adpcm_ct adpcm_g722 adpcm_g726 adpcm_ima_dk3 adpcm_ima_dk4 adpcm_ima_oki "
            "adpcm_ima_wav adpcm_ima_xbox adpcm_ms adpcm_sanyo adpcm_yamaha adpcm_zork amr_nb amr_wb av1 dpx dts "
            "eac3 ffv1 ffvhuff flac flv1 h263 h264 huffyuv mjpeg mp2 mp3 mpeg1video mpeg2video mpeg4 msmpeg4v3 "
            "pcm_alaw pcm_f32le pcm_f64le pcm_mulaw pcm_s16le pcm_s24le pcm_s32le pcm_s64le pcm_u8 snow tscc "
            "vorbis vp8 vp9"
        ),
        "android": (
            "amv asv1 asv2 cfhd cinepak cljr dirac dvvideo flashsv g723_1 gsm_ms h261 jpeg2000 jpegls magicyuv msrle msvideo1 "
            "png r10k r210 rawvideo rpza speedhq svq1 targa utvideo v210 y41p yuv4 zlib zmbv"
        ),
    },
    ("au", "au", "au"): {
        "android": ("adpcm_g722 pcm_f32be pcm_f64be pcm_mulaw pcm_s16be pcm_s24be pcm_s32be pcm_s8"),
    },
    ("avi", "avi", "avi"): {
        "both": (
            "aac aac_latm ac3 adpcm_ct adpcm_g722 adpcm_g726 adpcm_ima_dk3 adpcm_ima_dk4 adpcm_ima_oki "
            "adpcm_ima_wav adpcm_ima_xbox adpcm_ms adpcm_sanyo adpcm_yamaha adpcm_zork amr_nb amr_wb av1 dpx dts "
            "eac3 ffv1 flac flv1 h264 mp2 mpeg1video mpeg2video pcm_alaw pcm_f32le pcm_f64le pcm_mulaw "
            "pcm_s16le pcm_s24le pcm_s32le pcm_s64le pcm_u8 vorbis vp8 vp9 wmav1 wmav2 wmv1 wmv2"
        ),
        "android": ("cfhd dirac dvvideo flashsv g723_1 gsm_ms h261 jpeg2000 png r10k r210 rawvideo rpza svq1 targa v210 yuv4"),
    },
    ("caf", "caf", "caf"): {
        "both": (
            "ac3 adpcm_ima_qt adpcm_ima_wav adpcm_ms amr_nb flac mp1 mp2 mp3 pcm_alaw pcm_f32be pcm_f64be pcm_f64le "
            "pcm_mulaw pcm_s16be pcm_s24be pcm_s24le pcm_s32be pcm_s32le pcm_s8"
        ),
        "android": "gsm gsm_ms ilbc",
    },
    ("flv", "flv", "flv"): {
        "both": ("aac ac3 av1 eac3 flac h264 hevc mp3 opus pcm_alaw pcm_mulaw vp9"),
    },
    ("live_flv", "flv", "flv"): {
        "both": "aac ac3 adpcm_swf av1 eac3 flac h264 hevc mp3 opus pcm_alaw pcm_mulaw vp9",
    },
    ("ivf", "ivf", "ivf"): {
        # FFV1 and raw video use the explicit inputs above. Their default inputs need stream headers that IVF omits.
        "android": " ".join((*(codec for codec in IVF_PACKET_TAGS if codec not in {"ffv1", "rawvideo"}), "vp8", "vp9")),
    },
    ("matroska", "matroska", "mkv"): {
        "both": (
            "aac ac3 alac dts eac3 flac mjpeg mp1 mp2 mp3 mpeg1video mpeg2video mpeg4 msmpeg4v3 opus pcm_f32le pcm_f64le "
            "pcm_s16be pcm_s16le pcm_s24be pcm_s24le pcm_s32be pcm_s32le pcm_u8 prores snow vorbis vp8"
        ),
        "android": ("dirac jpeg2000 mlp png ra_144 rawvideo wavpack"),
    },
    ("mov", "mov", "mov"): {
        "both": (
            "aac ac3 alac amr_nb amr_wb dts eac3 flv1 hevc mjpeg mp1 mp2 mp3 mpeg1video mpeg2video mpeg4 msmpeg4v3 pcm_alaw "
            "pcm_f32be pcm_f32le pcm_f64be pcm_f64le pcm_mulaw pcm_s16be pcm_s24be pcm_s24le pcm_s32be "
            "pcm_s32le pcm_s8 pcm_u8 vorbis"
        ),
        "android": ("cinepak dirac dnxhd gif gsm ilbc magicyuv msrle nellymoser y41p"),
    },
    ("mov", "mp4", "mp4"): {"both": "av1 flac opus truehd vp9"},
    ("mpeg", "vob", "vob"): {
        "both": ("ac3 dts mp2"),
    },
    ("mpegts", "mpegts", "ts"): {
        "both": ("aac_latm ac3 eac3 hevc mp3 mpeg2video mpeg4 opus"),
        "android": "dts truehd",
    },
    ("nut", "nut", "nut"): {
        "android": (
            "aac aac_latm ac3 adpcm_ct adpcm_g722 adpcm_ima_oki adpcm_ima_wav adpcm_swf adpcm_yamaha amr_nb amr_wb amv asv1 asv2 av1 "
            "cfhd cinepak cljr dirac dpx dts dvvideo ffv1 ffvhuff flac flashsv flv1 g723_1 gif gsm_ms h261 h263 h264 hevc "
            "huffyuv jpeg2000 jpegls magicyuv mjpeg mp2 mp3 mpeg2video mpeg4 msmpeg4v3 msvideo1 opus pcm_alaw "
            "pcm_f32be pcm_f32le pcm_f64be pcm_f64le pcm_mulaw pcm_s16be pcm_s16be_planar pcm_s16le pcm_s24be "
            "pcm_s24le pcm_s32be pcm_s32le pcm_s64le pcm_s8 pcm_u8 pcm_u16le pcm_u24le pcm_u32le png r10k r210 rpza snow speedhq svq1 targa "
            "utvideo v210 vorbis vp8 vp9 wavpack wmv1 wmv2 y41p yuv4 zlib zmbv"
        ),
    },
    ("ogg", "ogg", "ogg"): {
        "both": ("flac vp8"),
    },
    ("rm", "rm", "rm"): {
        "both": ("aac ac3"),
    },
    ("swf", "swf", "swf"): {"android": "mjpeg"},
    ("voc", "voc", "voc"): {
        "android": ("adpcm_ct pcm_alaw pcm_mulaw pcm_s16le pcm_u8"),
    },
    ("w64", "w64", "w64"): {
        "android": (
            "aac_latm ac3 adpcm_ct adpcm_g722 adpcm_g726 adpcm_ima_dk3 adpcm_ima_dk4 adpcm_ima_oki adpcm_ima_wav "
            "adpcm_ima_xbox adpcm_ms adpcm_sanyo adpcm_yamaha adpcm_zork amr_nb amr_wb dts eac3 flac g723_1 gsm_ms "
            "mp2 mp3 pcm_alaw pcm_f32le pcm_f64le pcm_mulaw pcm_s16le pcm_s24le pcm_s32le pcm_s64le "
            "pcm_u8 wmav1 wmav2"
        ),
    },
    ("wav", "wav", "wav"): {
        "both": ("aac_latm ac3 amr_nb amr_wb dts eac3 flac mp2 mp3 pcm_f32le pcm_s16le wmav1 wmav2"),
        "android": ("g723_1"),
    },
    ("webm", "webm", "webm"): {
        "both": ("av1"),
    },
    ("wtv", "wtv", "wtv"): {"android": "mp3"},
}
