#include "mpvui_hls.h"

#include <errno.h>
#include <math.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <string.h>
#include <libavcodec/avcodec.h>
#include <libavfilter/avfilter.h>
#include <libavfilter/buffersink.h>
#include <libavfilter/buffersrc.h>
#include <libavformat/avformat.h>
#include <libavutil/avstring.h>
#include <libavutil/channel_layout.h>
#include <libavutil/dovi_meta.h>
#include <libavutil/mastering_display_metadata.h>
#include <libavutil/opt.h>
#include <libavutil/pixdesc.h>
#include <libavutil/time.h>

/* Process media serially under the gate so pausing waits for GPU work to finish.
 * Atomic cancellation lets the demuxer stop while the gate is held. */
typedef struct Track {
    AVStream *input, *output;
    AVCodecContext *decoder, *encoder;
    AVFilterGraph *graph;
    AVFilterContext *source, *sink;
    int copy, hdr;
    int64_t next_dts;
} Track;

struct mpvui_hls {
    char *url, *playlist;
    AVDictionary *options;
    AVFormatContext *input, *output;
    Track video, audio;
    AVPacket *first;
    double requested_start, origin, input_start, playback;
    int video_index, audio_index, header_written, probed, prepared;
    pthread_mutex_t gate;
    pthread_cond_t condition;
    atomic_int cancelled;
    int paused;
    char error[256];
};

static int failure(mpvui_hls *s, int code, const char *operation) {
    char detail[AV_ERROR_MAX_STRING_SIZE];
    av_strerror(code, detail, sizeof(detail));
    snprintf(s->error, sizeof(s->error), "%s: %s", operation, detail);
    return code;
}

static int interrupted(void *opaque) {
    mpvui_hls *s = opaque;
    return atomic_load(&s->cancelled);
}

mpvui_hls *mpvui_hls_create(const char *source, const char *playlist, double start_time, int video, int audio) {
    if (!source || !isfinite(start_time) || start_time < 0)
        return NULL;
    mpvui_hls *s = av_mallocz(sizeof(*s));
    if (!s)
        return NULL;
    s->url = av_strdup(source);
    s->playlist = playlist ? av_strdup(playlist) : NULL;
    s->requested_start = s->playback = start_time;
    s->video_index = video;
    s->audio_index = audio;
    pthread_mutex_init(&s->gate, NULL);
    pthread_cond_init(&s->condition, NULL);
    atomic_init(&s->cancelled, 0);
    if (!s->url || (playlist && !s->playlist)) {
        mpvui_hls_destroy(s);
        return NULL;
    }
    return s;
}

int mpvui_hls_set_option(mpvui_hls *s, const char *key, const char *value) { return av_dict_set(&s->options, key, value, 0); }

static int select_track(mpvui_hls *s, int index, enum AVMediaType type, Track *track) {
    if (index == -2)
        return 0;
    if (index == -1) {
        index = av_find_best_stream(s->input, type, -1, -1, NULL, 0);
        if (index == AVERROR_STREAM_NOT_FOUND)
            return 0;
    }
    if (index < 0 || index >= (int)s->input->nb_streams || s->input->streams[index]->codecpar->codec_type != type)
        return AVERROR_STREAM_NOT_FOUND;
    track->input = s->input->streams[index];
    if (track->input->disposition & AV_DISPOSITION_ATTACHED_PIC) {
        track->input = NULL;
        return 0;
    }
    return 0;
}

static const AVDOVIDecoderConfigurationRecord *dovi(AVCodecParameters *p) {
    const AVPacketSideData *data = av_packet_side_data_get(p->coded_side_data, p->nb_coded_side_data, AV_PKT_DATA_DOVI_CONF);
    return data && data->size >= sizeof(AVDOVIDecoderConfigurationRecord) ? (const AVDOVIDecoderConfigurationRecord *)data->data : NULL;
}

static int copy_video(AVStream *stream) {
    AVCodecParameters *p = stream->codecpar;
    AVRational rate = stream->avg_frame_rate.num ? stream->avg_frame_rate : stream->r_frame_rate;
    const AVPixFmtDescriptor *format = av_pix_fmt_desc_get(p->format);
    if (!format || format->log2_chroma_w != 1 || format->log2_chroma_h != 1 || format->nb_components != 3 || p->extradata_size == 0 ||
        (rate.num <= 0 || rate.den <= 0 || av_q2d(rate) > 60.01) ||
        (p->field_order != AV_FIELD_UNKNOWN && p->field_order != AV_FIELD_PROGRESSIVE))
        return 0;
    if (p->codec_id == AV_CODEC_ID_H264)
        return format->comp[0].depth == 8 && p->level > 0 && p->level <= 52 &&
               (p->profile == AV_PROFILE_H264_BASELINE || p->profile == AV_PROFILE_H264_CONSTRAINED_BASELINE ||
                p->profile == AV_PROFILE_H264_MAIN || p->profile == AV_PROFILE_H264_HIGH) &&
               p->color_trc != AVCOL_TRC_SMPTE2084 && p->color_trc != AVCOL_TRC_ARIB_STD_B67;
    if (p->codec_id != AV_CODEC_ID_HEVC || format->comp[0].depth > 10 || p->level <= 0 || p->level > 153 ||
        (p->profile != AV_PROFILE_HEVC_MAIN && p->profile != AV_PROFILE_HEVC_MAIN_10))
        return 0;
    const AVDOVIDecoderConfigurationRecord *dv = dovi(p);
    return !dv || (!dv->el_present_flag && dv->bl_present_flag && dv->dv_level <= 7 && dv->dv_md_compression == AV_DOVI_COMPRESSION_NONE &&
                   (dv->dv_profile == 5 ||
                    (dv->dv_profile == 8 && (dv->dv_bl_signal_compatibility_id == 1 || dv->dv_bl_signal_compatibility_id == 4))));
}

static int copy_audio(AVCodecParameters *p) {
    if (p->ch_layout.nb_channels < 1 || p->ch_layout.nb_channels > 8 || p->sample_rate < 8000 || p->sample_rate > 48000)
        return 0;
    switch (p->codec_id) {
    case AV_CODEC_ID_AAC:
        return p->extradata_size > 0 &&
               (p->profile == AV_PROFILE_AAC_LOW || p->profile == AV_PROFILE_AAC_HE || p->profile == AV_PROFILE_AAC_HE_V2);
    case AV_CODEC_ID_AC3:
    case AV_CODEC_ID_EAC3:
        return 1;
    default:
        return 0;
    }
}

static int create_track(mpvui_hls *s, Track *t) {
    if (!t->input)
        return 0;
    t->next_dts = AV_NOPTS_VALUE;
    AVCodecParameters *p = t->input->codecpar;
    int video = p->codec_type == AVMEDIA_TYPE_VIDEO;
    if (video && !t->input->avg_frame_rate.num)
        t->input->avg_frame_rate = t->input->r_frame_rate;
    t->output = avformat_new_stream(s->output, NULL);
    if (!t->output)
        return AVERROR(ENOMEM);
    t->output->time_base = t->input->time_base;
    t->output->avg_frame_rate = t->input->avg_frame_rate;
    t->output->sample_aspect_ratio = t->input->sample_aspect_ratio;
    int ret;
    if (t->copy) {
        if ((ret = avcodec_parameters_copy(t->output->codecpar, p)) < 0)
            return ret;
        t->output->codecpar->codec_tag =
            video ? (p->codec_id == AV_CODEC_ID_HEVC ? MKTAG('h', 'v', 'c', '1') : MKTAG('a', 'v', 'c', '1')) : 0;
        // Matroska tracks may have no bitrate, but the HLS variant needs an estimate.
        // Swift replaces this estimate using the completed startup segments.
        if (t->output->codecpar->bit_rate <= 0)
            t->output->codecpar->bit_rate = video ? FFMAX(s->input->bit_rate, 6000000) : 192000;
        return 0;
    }
    const AVCodec *decoder = avcodec_find_decoder(p->codec_id);
    const AVCodec *encoder = avcodec_find_encoder_by_name(video ? "h264_videotoolbox" : "aac");
    if (!decoder || !encoder)
        return AVERROR_ENCODER_NOT_FOUND;
    t->decoder = avcodec_alloc_context3(decoder);
    t->encoder = avcodec_alloc_context3(encoder);
    if (!t->decoder || !t->encoder)
        return AVERROR(ENOMEM);
    if ((ret = avcodec_parameters_to_context(t->decoder, p)) < 0)
        return ret;
    t->decoder->pkt_timebase = t->input->time_base;
    t->decoder->thread_count = 2;
    if ((ret = avcodec_open2(t->decoder, decoder, NULL)) < 0)
        return ret;
    AVCodecContext *e = t->encoder;
    e->flags |= AV_CODEC_FLAG_GLOBAL_HEADER;
    if (video) {
        double scale = fmin(1, fmin(1920.0 / p->width, 1080.0 / p->height));
        e->width = FFMAX(2, ((int)(p->width * scale) / 2) * 2);
        e->height = FFMAX(2, ((int)(p->height * scale) / 2) * 2);
        e->pix_fmt = AV_PIX_FMT_YUV420P;
        e->time_base = (AVRational){1, 30};
        e->framerate = (AVRational){30, 1};
        e->gop_size = 60;
        e->max_b_frames = 0;
        e->bit_rate = 6000000;
        e->sample_aspect_ratio = p->sample_aspect_ratio;
        e->color_primaries = t->hdr ? AVCOL_PRI_BT709 : p->color_primaries;
        e->color_trc = t->hdr ? AVCOL_TRC_BT709 : p->color_trc;
        e->colorspace = t->hdr ? AVCOL_SPC_BT709 : p->color_space;
        e->color_range = t->hdr ? AVCOL_RANGE_MPEG : p->color_range;
        av_opt_set(e->priv_data, "allow_sw", "1", 0);
        av_opt_set(e->priv_data, "profile", "high", 0);
        av_opt_set(e->priv_data, "level", "4.1", 0);
        t->output->avg_frame_rate = e->framerate;
    } else {
        e->sample_fmt = AV_SAMPLE_FMT_FLTP;
        e->sample_rate = 48000;
        e->time_base = (AVRational){1, 48000};
        /* Use standard AAC channel layouts for surround output up to 7.1. */
        int channels = p->ch_layout.nb_channels;
        if (channels <= 0)
            return AVERROR_INVALIDDATA;
        if (channels > 8)
            channels = 8;
        av_channel_layout_default(&e->ch_layout, channels);
        e->bit_rate = channels <= 2 ? 192000 : channels * 64000;
    }
    if ((ret = avcodec_open2(e, encoder, NULL)) < 0)
        return ret;
    t->output->time_base = e->time_base;
    return avcodec_parameters_from_context(t->output->codecpar, e);
}

/* Start at the preceding video keyframe and give both tracks the same time origin.
 * Preserve audio alignment and the timestamps needed to decode reordered video. */
static int find_start(mpvui_hls *s) {
    int64_t target = llrint((s->input_start + s->requested_start) * AV_TIME_BASE);
    if (s->requested_start > 0) {
        int ret = avformat_seek_file(s->input, -1, INT64_MIN, target, target, 0);
        if (ret < 0)
            return ret;
    }
    s->first = av_packet_alloc();
    if (!s->first)
        return AVERROR(ENOMEM);
    Track *reference = s->video.input ? &s->video : &s->audio;
    for (;;) {
        int ret = av_read_frame(s->input, s->first);
        if (ret < 0)
            return ret;
        if (s->first->stream_index == reference->input->index && (!s->video.input || (s->first->flags & AV_PKT_FLAG_KEY)) &&
            s->first->pts != AV_NOPTS_VALUE) {
            s->origin = s->first->pts * av_q2d(reference->input->time_base);
            return 0;
        }
        av_packet_unref(s->first);
    }
}

/* Decode the first keyframe to read color and HDR metadata that the container may omit.
 * Keep the compressed packet unchanged for remuxing. */
static void probe_video_signal(mpvui_hls *s) {
    if (!s->video.input)
        return;
    AVCodecParameters *p = s->video.input->codecpar;
    const AVCodec *codec = avcodec_find_decoder(p->codec_id);
    if (!codec)
        return;
    AVCodecContext *decoder = avcodec_alloc_context3(codec);
    AVFrame *frame = av_frame_alloc();
    if (!decoder || !frame)
        goto done;
    if (avcodec_parameters_to_context(decoder, p) < 0)
        goto done;
    decoder->thread_count = 1;
    if (avcodec_open2(decoder, codec, NULL) < 0 || avcodec_send_packet(decoder, s->first) < 0)
        goto done;
    int ret = avcodec_receive_frame(decoder, frame);
    if (ret == AVERROR(EAGAIN)) {
        if (avcodec_send_packet(decoder, NULL) < 0)
            goto done;
        ret = avcodec_receive_frame(decoder, frame);
    }
    if (ret < 0)
        goto done;
    p->color_trc = frame->color_trc;
    p->color_primaries = frame->color_primaries;
    p->color_space = frame->colorspace;
    p->color_range = frame->color_range;
    if (frame->flags & AV_FRAME_FLAG_INTERLACED)
        p->field_order = AV_FIELD_TT;
    const enum AVFrameSideDataType frame_types[] = {AV_FRAME_DATA_MASTERING_DISPLAY_METADATA, AV_FRAME_DATA_CONTENT_LIGHT_LEVEL};
    const enum AVPacketSideDataType packet_types[] = {AV_PKT_DATA_MASTERING_DISPLAY_METADATA, AV_PKT_DATA_CONTENT_LIGHT_LEVEL};
    for (int i = 0; i < 2; i++) {
        const AVFrameSideData *data = av_frame_get_side_data(frame, frame_types[i]);
        if (!data || av_packet_side_data_get(p->coded_side_data, p->nb_coded_side_data, packet_types[i]))
            continue;
        AVPacketSideData *copy = av_packet_side_data_new(&p->coded_side_data, &p->nb_coded_side_data, packet_types[i], data->size, 0);
        if (copy)
            memcpy(copy->data, data->data, data->size);
    }
done:
    av_frame_free(&frame);
    avcodec_free_context(&decoder);
}

/* Build RFC 6381 codec strings for the HLS playlist.
 * Parse HEVC hvcC data from MP4 and Matroska because FFmpeg's HLS writer handles only Annex B data. */
static void codec_strings(mpvui_hls *s, mpvui_hls_info *info) {
    if (s->video.output) {
        AVCodecParameters *p = s->video.output->codecpar;
        const uint8_t *h = p->extradata;
        if (!s->video.copy) {
            snprintf(info->video_codec, sizeof(info->video_codec), "avc1.640029");
        } else if (p->codec_id == AV_CODEC_ID_H264 && p->extradata_size >= 4 && h[0] == 1) {
            snprintf(info->video_codec, sizeof(info->video_codec), "avc1.%02X%02X%02X", h[1], h[2], h[3]);
        } else if (p->codec_id == AV_CODEC_ID_HEVC && p->extradata_size >= 23 && h[0] == 1) {
            uint32_t flags = ((uint32_t)h[2] << 24) | ((uint32_t)h[3] << 16) | ((uint32_t)h[4] << 8) | h[5];
            uint32_t reversed = 0;
            for (int i = 0; i < 32; i++) {
                reversed = (reversed << 1) | (flags & 1);
                flags >>= 1;
            }
            char space[2] = {0};
            if (h[1] >> 6)
                space[0] = 'A' + (h[1] >> 6) - 1;
            snprintf(info->video_codec, sizeof(info->video_codec), "hvc1.%s%d.%X.%c%d", space, h[1] & 31, reversed, h[1] & 32 ? 'H' : 'L',
                     h[12]);
            int last = 11;
            while (last >= 6 && !h[last])
                last--;
            for (int i = 6; i <= last; i++) {
                size_t length = strlen(info->video_codec);
                snprintf(info->video_codec + length, sizeof(info->video_codec) - length, ".%02X", h[i]);
            }
        }
    }
    if (s->audio.output) {
        AVCodecParameters *p = s->audio.output->codecpar;
        if (p->codec_id == AV_CODEC_ID_AAC)
            snprintf(info->audio_codec, sizeof(info->audio_codec), "mp4a.40.%d",
                     p->profile == AV_PROFILE_AAC_HE      ? 5
                     : p->profile == AV_PROFILE_AAC_HE_V2 ? 29
                                                          : 2);
        else
            snprintf(info->audio_codec, sizeof(info->audio_codec), "%s", p->codec_id == AV_CODEC_ID_AC3 ? "ac-3" : "ec-3");
        info->audio_channels = p->ch_layout.nb_channels;
        info->audio_joc = p->profile == AV_PROFILE_EAC3_DDP_ATMOS;
    }
}

static int probe_source(mpvui_hls *s) {
    if (s->probed)
        return 0;
    int ret;
    s->input = avformat_alloc_context();
    if (!s->input)
        return failure(s, AVERROR(ENOMEM), "Allocate input");
    s->input->interrupt_callback = (AVIOInterruptCB){interrupted, s};
    if ((ret = avformat_open_input(&s->input, s->url, NULL, &s->options)) < 0)
        return failure(s, ret, "Open source");
    if ((ret = avformat_find_stream_info(s->input, NULL)) < 0)
        return failure(s, ret, "Probe source");
    if ((ret = select_track(s, s->video_index, AVMEDIA_TYPE_VIDEO, &s->video)) < 0 ||
        (ret = select_track(s, s->audio_index, AVMEDIA_TYPE_AUDIO, &s->audio)) < 0)
        return failure(s, ret, "Select source track");
    if (!s->video.input && !s->audio.input)
        return failure(s, AVERROR_STREAM_NOT_FOUND, "No selected media");
    s->input_start = s->input->start_time == AV_NOPTS_VALUE ? 0 : (double)s->input->start_time / AV_TIME_BASE;
    if ((ret = find_start(s)) < 0)
        return failure(s, ret, "Seek source");
    probe_video_signal(s);
    if (s->video.input) {
        AVCodecParameters *p = s->video.input->codecpar;
        s->video.copy = copy_video(s->video.input);
        s->video.hdr = p->color_trc == AVCOL_TRC_SMPTE2084 || p->color_trc == AVCOL_TRC_ARIB_STD_B67 || dovi(p);
    }
    if (s->audio.input)
        s->audio.copy = copy_audio(s->audio.input->codecpar);
    s->probed = 1;
    return 0;
}

int mpvui_hls_probe(mpvui_hls *s, mpvui_hls_plan *plan) {
    int ret = probe_source(s);
    if (ret < 0)
        return ret;
    *plan = (mpvui_hls_plan){.has_video = !!s->video.input,
                             .has_audio = !!s->audio.input,
                             .video_copied = s->video.copy,
                             .audio_copied = s->audio.copy,
                             .requires_foreground = s->video.hdr && !s->video.copy};
    return 0;
}

int mpvui_hls_prepare(mpvui_hls *s, mpvui_hls_info *info) {
    if (!s->playlist)
        return failure(s, AVERROR(EINVAL), "Missing HLS output path");
    int ret = probe_source(s);
    if (ret < 0)
        return ret;
    if ((ret = avformat_alloc_output_context2(&s->output, NULL, "hls", s->playlist)) < 0)
        return failure(s, ret, "Create HLS output");
    s->output->interrupt_callback = (AVIOInterruptCB){interrupted, s};
    if ((ret = create_track(s, &s->video)) < 0 || (ret = create_track(s, &s->audio)) < 0)
        return failure(s, ret, "Prepare media tracks");
    /* Allow the Dolby Vision configuration box without changing compressed packets or RPU metadata. */
    s->output->strict_std_compliance = FF_COMPLIANCE_UNOFFICIAL;
    AVDictionary *options = NULL;
    av_dict_set(&options, "hls_time", "2", 0);
    av_dict_set(&options, "hls_list_size", "60", 0);
    av_dict_set(&options, "hls_flags", "delete_segments+independent_segments+temp_file", 0);
    av_dict_set(&options, "hls_segment_type", "fmp4", 0);
    av_dict_set(&options, "hls_fmp4_init_filename", "init.mp4", 0);
    av_dict_set(&options, "hls_segment_options", "strict=-1", 0);
    av_dict_set(&options, "master_pl_name", "master.m3u8", 0);
    ret = avformat_write_header(s->output, &options);
    av_dict_free(&options);
    if (ret < 0)
        return failure(s, ret, "Write HLS header");
    s->header_written = 1;
    *info = (mpvui_hls_info){.has_video = !!s->video.input,
                             .has_audio = !!s->audio.input,
                             .video_copied = s->video.copy,
                             .audio_copied = s->audio.copy,
                             .requires_foreground = s->video.hdr && !s->video.copy,
                             .frame_rate = s->video.output ? av_q2d(s->video.output->avg_frame_rate) : 0,
                             .start_time = s->origin - s->input_start};
    if (s->video.copy) {
        AVCodecParameters *p = s->video.input->codecpar;
        info->video_range = p->color_trc == AVCOL_TRC_SMPTE2084 ? 1 : p->color_trc == AVCOL_TRC_ARIB_STD_B67 ? 2 : 0;
        const AVDOVIDecoderConfigurationRecord *dv = dovi(p);
        if (dv) {
            info->dolby_vision_profile = dv->dv_profile;
            info->dolby_vision_level = dv->dv_level;
            info->video_range = dv->dv_profile == 5 || dv->dv_bl_signal_compatibility_id == 1 ? 1 : 2;
        }
    }
    codec_strings(s, info);
    s->prepared = 1;
    return 0;
}

static int create_filters(Track *t, AVFrame *frame) {
    int video = t->input->codecpar->codec_type == AVMEDIA_TYPE_VIDEO;
    t->graph = avfilter_graph_alloc();
    if (!t->graph)
        return AVERROR(ENOMEM);
    t->graph->nb_threads = 2;
    char args[512], description[1024];
    if (video) {
        AVRational sar = frame->sample_aspect_ratio.num ? frame->sample_aspect_ratio : (AVRational){1, 1};
        snprintf(args, sizeof(args), "video_size=%dx%d:pix_fmt=%d:time_base=%d/%d:pixel_aspect=%d/%d", frame->width, frame->height,
                 frame->format, t->input->time_base.num, t->input->time_base.den, sar.num, sar.den);
        const char *deinterlace = t->input->codecpar->field_order != AV_FIELD_PROGRESSIVE ? "bwdif=mode=send_frame:deint=interlaced," : "";
        if (t->hdr)
            snprintf(description, sizeof(description),
                     "%slibplacebo=w=%d:h=%d:format=yuv420p:colorspace=bt709:color_primaries=bt709:color_trc=bt709:range=tv,fps=30",
                     deinterlace, t->encoder->width, t->encoder->height);
        else
            snprintf(description, sizeof(description), "%sscale=%d:%d,format=yuv420p,fps=30", deinterlace, t->encoder->width,
                     t->encoder->height);
    } else {
        char layout[128], output_layout[128];
        av_channel_layout_describe(&frame->ch_layout, layout, sizeof(layout));
        av_channel_layout_describe(&t->encoder->ch_layout, output_layout, sizeof(output_layout));
        snprintf(args, sizeof(args), "time_base=%d/%d:sample_rate=%d:sample_fmt=%s:channel_layout=%s", t->input->time_base.num,
                 t->input->time_base.den, frame->sample_rate, av_get_sample_fmt_name(frame->format), layout);
        snprintf(description, sizeof(description), "aresample=48000,aformat=sample_fmts=fltp:channel_layouts=%s", output_layout);
    }
    int ret = avfilter_graph_create_filter(&t->source, avfilter_get_by_name(video ? "buffer" : "abuffer"), "in", args, NULL, t->graph);
    if (ret < 0)
        return ret;
    ret = avfilter_graph_create_filter(&t->sink, avfilter_get_by_name(video ? "buffersink" : "abuffersink"), "out", NULL, NULL, t->graph);
    if (ret < 0)
        return ret;
    AVFilterInOut *inputs = avfilter_inout_alloc(), *outputs = avfilter_inout_alloc();
    if (!inputs || !outputs) {
        avfilter_inout_free(&inputs);
        avfilter_inout_free(&outputs);
        return AVERROR(ENOMEM);
    }
    inputs->name = av_strdup("out");
    inputs->filter_ctx = t->sink;
    outputs->name = av_strdup("in");
    outputs->filter_ctx = t->source;
    ret = avfilter_graph_parse_ptr(t->graph, description, &inputs, &outputs, NULL);
    avfilter_inout_free(&inputs);
    avfilter_inout_free(&outputs);
    if (ret < 0)
        return ret;
    if ((ret = avfilter_graph_config(t->graph, NULL)) < 0)
        return ret;
    if (!video)
        av_buffersink_set_frame_size(t->sink, t->encoder->frame_size);
    return 0;
}

static int encode(mpvui_hls *s, Track *t, AVFrame *frame) {
    int ret = avcodec_send_frame(t->encoder, frame);
    if (ret < 0)
        return ret;
    AVPacket *packet = av_packet_alloc();
    if (!packet)
        return AVERROR(ENOMEM);
    while ((ret = avcodec_receive_packet(t->encoder, packet)) >= 0) {
        av_packet_rescale_ts(packet, t->encoder->time_base, t->output->time_base);
        packet->stream_index = t->output->index;
        ret = av_interleaved_write_frame(s->output, packet);
        if (ret < 0)
            break;
    }
    av_packet_free(&packet);
    return ret == AVERROR(EAGAIN) || ret == AVERROR_EOF ? 0 : ret;
}

static int filter(mpvui_hls *s, Track *t, AVFrame *frame) {
    int ret;
    if (!t->graph) {
        if (!frame)
            return 0;
        if ((ret = create_filters(t, frame)) < 0)
            return ret;
    }
    if ((ret = av_buffersrc_add_frame_flags(t->source, frame, AV_BUFFERSRC_FLAG_KEEP_REF)) < 0)
        return ret;
    AVFrame *filtered = av_frame_alloc();
    if (!filtered)
        return AVERROR(ENOMEM);
    while ((ret = av_buffersink_get_frame(t->sink, filtered)) >= 0) {
        filtered->pts = av_rescale_q(filtered->pts, av_buffersink_get_time_base(t->sink), t->encoder->time_base);
        filtered->pict_type = AV_PICTURE_TYPE_NONE;
        ret = encode(s, t, filtered);
        av_frame_unref(filtered);
        if (ret < 0)
            break;
    }
    av_frame_free(&filtered);
    return ret == AVERROR(EAGAIN) || ret == AVERROR_EOF ? 0 : ret;
}

static int transcode(mpvui_hls *s, Track *t, AVPacket *packet) {
    int ret = avcodec_send_packet(t->decoder, packet);
    if (ret < 0)
        return ret;
    AVFrame *frame = av_frame_alloc();
    if (!frame)
        return AVERROR(ENOMEM);
    while ((ret = avcodec_receive_frame(t->decoder, frame)) >= 0) {
        frame->pts = frame->best_effort_timestamp;
        if (frame->pts == AV_NOPTS_VALUE) {
            ret = AVERROR_INVALIDDATA;
            break;
        }
        frame->pts -= llrint(s->origin / av_q2d(t->input->time_base));
        if (frame->pts >= 0)
            ret = filter(s, t, frame);
        av_frame_unref(frame);
        if (ret < 0)
            break;
    }
    av_frame_free(&frame);
    return ret == AVERROR(EAGAIN) || ret == AVERROR_EOF ? 0 : ret;
}

static int process(mpvui_hls *s, AVPacket *packet) {
    Track *t = s->video.input && packet->stream_index == s->video.input->index   ? &s->video
               : s->audio.input && packet->stream_index == s->audio.input->index ? &s->audio
                                                                                 : NULL;
    if (!t)
        return 0;
    if (!t->copy)
        return transcode(s, t, packet);
    if (packet->pts == AV_NOPTS_VALUE)
        return AVERROR_INVALIDDATA;
    if (packet->dts == AV_NOPTS_VALUE) {
        // Matroska may omit decode timestamps for the first reordered frames after opening or seeking.
        // Reconstruct them using the frame duration and detected reorder depth.
        AVRational rate = t->input->avg_frame_rate;
        if (t == &s->video && (!rate.num || !rate.den))
            return AVERROR_INVALIDDATA;
        int64_t duration = t == &s->video ? av_rescale_q(1, av_inv_q(rate), t->input->time_base) : packet->duration;
        packet->dts = t->next_dts != AV_NOPTS_VALUE ? t->next_dts : packet->pts - t->input->codecpar->video_delay * duration;
        t->next_dts = packet->dts + duration;
    } else {
        t->next_dts = packet->dts + packet->duration;
    }
    int64_t offset = llrint(s->origin / av_q2d(t->input->time_base));
    packet->pts -= offset;
    packet->dts -= offset;
    /* Keep negative video decode timestamps for reordered frames. Skip audio before the shared time origin. */
    if (t == &s->audio && packet->pts < 0)
        return 0;
    av_packet_rescale_ts(packet, t->input->time_base, t->output->time_base);
    packet->stream_index = t->output->index;
    packet->pos = -1;
    return av_interleaved_write_frame(s->output, packet);
}

int mpvui_hls_run(mpvui_hls *s) {
    if (!s->prepared)
        return failure(s, AVERROR(EINVAL), "HLS is not prepared");
    AVPacket *packet = s->first;
    s->first = NULL;
    int ret = 0;
    for (;;) {
        int selected = (s->video.input && packet->stream_index == s->video.input->index) ||
                       (s->audio.input && packet->stream_index == s->audio.input->index);
        double position = !selected || packet->pts == AV_NOPTS_VALUE
                              ? 0
                              : packet->pts * av_q2d(s->input->streams[packet->stream_index]->time_base) - s->input_start;
        pthread_mutex_lock(&s->gate);
        /* Allow up to 60 seconds of lookahead so long keyframe intervals can produce complete segments. */
        while (!interrupted(s) && (s->paused || position > s->playback + 60))
            pthread_cond_wait(&s->condition, &s->gate);
        if (interrupted(s))
            ret = AVERROR_EXIT;
        else
            ret = process(s, packet);
        pthread_mutex_unlock(&s->gate);
        av_packet_unref(packet);
        if (ret < 0)
            break;
        ret = av_read_frame(s->input, packet);
        if (ret < 0)
            break;
    }
    av_packet_free(&packet);
    if (ret == AVERROR_EOF) {
        pthread_mutex_lock(&s->gate);
        while (!interrupted(s) && s->paused)
            pthread_cond_wait(&s->condition, &s->gate);
        ret = interrupted(s) ? AVERROR_EXIT : 0;
        Track *tracks[] = {&s->video, &s->audio};
        for (int i = 0; i < 2 && ret >= 0; i++) {
            Track *t = tracks[i];
            if (!t->encoder)
                continue;
            ret = transcode(s, t, NULL);
            if (ret >= 0)
                ret = filter(s, t, NULL);
            if (ret >= 0)
                ret = encode(s, t, NULL);
        }
        if (ret >= 0) {
            ret = av_write_trailer(s->output);
            s->header_written = 0;
        }
        pthread_mutex_unlock(&s->gate);
    }
    return ret < 0 ? failure(s, ret, "Package HLS media") : 0;
}

void mpvui_hls_set_playback_position(mpvui_hls *s, double seconds) {
    if (!isfinite(seconds))
        return;
    pthread_mutex_lock(&s->gate);
    s->playback = seconds;
    pthread_cond_broadcast(&s->condition);
    pthread_mutex_unlock(&s->gate);
}

void mpvui_hls_set_paused(mpvui_hls *s, int paused) {
    pthread_mutex_lock(&s->gate);
    s->paused = paused;
    pthread_cond_broadcast(&s->condition);
    pthread_mutex_unlock(&s->gate);
}

void mpvui_hls_cancel(mpvui_hls *s) {
    atomic_store(&s->cancelled, 1);
    pthread_mutex_lock(&s->gate);
    pthread_cond_broadcast(&s->condition);
    pthread_mutex_unlock(&s->gate);
}

const char *mpvui_hls_error(mpvui_hls *s) { return s->error; }

static void destroy_track(Track *t) {
    avfilter_graph_free(&t->graph);
    avcodec_free_context(&t->decoder);
    avcodec_free_context(&t->encoder);
}

void mpvui_hls_destroy(mpvui_hls *s) {
    if (!s)
        return;
    if (s->header_written) {
        // Finalize the muxer after cancellation to release fragment buffers and file handles.
        // Do not flush the encoder here because GPU work may already be suspended.
        atomic_store(&s->cancelled, 0);
        av_write_trailer(s->output);
    }
    destroy_track(&s->video);
    destroy_track(&s->audio);
    av_packet_free(&s->first);
    avformat_close_input(&s->input);
    avformat_free_context(s->output);
    av_dict_free(&s->options);
    av_free(s->url);
    av_free(s->playlist);
    pthread_cond_destroy(&s->condition);
    pthread_mutex_destroy(&s->gate);
    av_free(s);
}
