#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>

#include <libavutil/avutil.h>
#include <libavutil/log.h>
#include <libavutil/mem.h>
#include <libavutil/error.h>

#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>

static pthread_once_t g_log_once = PTHREAD_ONCE_INIT;

static void ff_log_init_once(void) {
    // 只保留错误（把刷屏的 Opening/Warning 全关掉）
    av_log_set_level(AV_LOG_ERROR);

    // av_log_set_level(0);
}

static void ensure_ff_log_inited(void) {
    pthread_once(&g_log_once, ff_log_init_once);
}

static void log_err(const char *tag, int err) {
    char buf[256];
    av_strerror(err, buf, sizeof(buf));
    fprintf(stderr, "[ffmpeg_remux][%s] err=%d %s\n", tag, err, buf);
}

static int is_av_stream(const AVCodecParameters *par) {
    return par->codec_type == AVMEDIA_TYPE_VIDEO || par->codec_type == AVMEDIA_TYPE_AUDIO;
}

// 读取一些包后再尝试获取 width/height 等参数（避免 mp4 write_header 报 dimensions not set）
static int ensure_video_params_ready(AVFormatContext *ifmt, int max_packets_to_probe) {
    if (!ifmt) return AVERROR(EINVAL);

    // 先看 stream_info 结果
    for (unsigned int i = 0; i < ifmt->nb_streams; i++) {
        AVStream *st = ifmt->streams[i];
        if (st && st->codecpar && st->codecpar->codec_type == AVMEDIA_TYPE_VIDEO) {
            if (st->codecpar->width > 0 && st->codecpar->height > 0) return 0;
        }
    }

    // 不够就再读一些包，让 demuxer/codecpar 变完整
    AVPacket pkt;
    av_init_packet(&pkt);

    int ret = 0;
    for (int k = 0; k < max_packets_to_probe; k++) {
        ret = av_read_frame(ifmt, &pkt);
        if (ret < 0) break;

        // 触发 parser/stream_info 进展
        av_packet_unref(&pkt);

        // 再检查一次
        for (unsigned int i = 0; i < ifmt->nb_streams; i++) {
            AVStream *st = ifmt->streams[i];
            if (st && st->codecpar && st->codecpar->codec_type == AVMEDIA_TYPE_VIDEO) {
                if (st->codecpar->width > 0 && st->codecpar->height > 0) return 0;
            }
        }
    }

    // 仍然没有尺寸
    return AVERROR(EINVAL);
}

static int remux_internal(const char *in_m3u8, const char *out_mp4, int video_only) {
    AVFormatContext *ifmt = NULL;
    AVFormatContext *ofmt = NULL;
    AVDictionary *iopts = NULL;

    int ret = 0;

    // Hint demuxer as HLS
    AVInputFormat *hls_ifmt = av_find_input_format("hls");

    // AES-128 HLS 本地：必须允许 crypto/file/data
    av_dict_set(&iopts, "protocol_whitelist", "file,crypto,data", 0);
    av_dict_set(&iopts, "allowed_extensions", "ALL", 0);

    // 加大探测，避免 dimensions not set / sample rate not set
    // analyzeduration 单位：微秒
    av_dict_set(&iopts, "analyzeduration", "40000000", 0); // 40s
    av_dict_set(&iopts, "probesize", "100000000", 0);      // 100MB

    // Open input
    ret = avformat_open_input(&ifmt, in_m3u8, hls_ifmt, &iopts);
    av_dict_free(&iopts);
    if (ret < 0) { log_err("open_input", ret); goto end; }

    ret = avformat_find_stream_info(ifmt, NULL);
    if (ret < 0) { log_err("find_stream_info", ret); goto end; }

    // 如果 video width/height 仍没出来，额外读一些包
    //（不走 decoder，只为了把 codecpar 变完整）
    int probe_ret = ensure_video_params_ready(ifmt, 200);
    if (probe_ret < 0) {
        // 不直接失败，继续走 remux，让后续 write_header 决定是否失败
        // 但很多情况下这里失败就会导致 mp4 header fail
        // 更严格：ret = probe_ret; goto end;
    }

    // Create output context (force mp4)
    ret = avformat_alloc_output_context2(&ofmt, NULL, "mp4", out_mp4);
    if (ret < 0 || !ofmt) { log_err("alloc_output", ret); goto end; }

    int stream_mapping_size = (int)ifmt->nb_streams;
    int *stream_mapping = (int *)av_calloc(stream_mapping_size, sizeof(*stream_mapping));
    if (!stream_mapping) { ret = AVERROR(ENOMEM); log_err("alloc_mapping", ret); goto end; }

    int out_index = 0;
    for (unsigned int i = 0; i < ifmt->nb_streams; i++) {
        AVStream *in_st = ifmt->streams[i];
        AVCodecParameters *in_par = in_st->codecpar;

        if (!is_av_stream(in_par)) {
            stream_mapping[i] = -1;
            continue;
        }
        if (video_only && in_par->codec_type != AVMEDIA_TYPE_VIDEO) {
            stream_mapping[i] = -1;
            continue;
        }

        AVStream *out_st = avformat_new_stream(ofmt, NULL);
        if (!out_st) { ret = AVERROR_UNKNOWN; log_err("new_stream", ret); goto end_map; }

        ret = avcodec_parameters_copy(out_st->codecpar, in_par);
        if (ret < 0) { log_err("copy_codecpar", ret); goto end_map; }

        // mp4 muxer 决定 tag
        out_st->codecpar->codec_tag = 0;

        // timebase
        out_st->time_base = in_st->time_base;

        stream_mapping[i] = out_index++;
    }

    if (out_index <= 0) {
        ret = AVERROR_INVALIDDATA;
        log_err("no_streams", ret);
        goto end_map;
    }

    // Open output IO
    if (!(ofmt->oformat->flags & AVFMT_NOFILE)) {
        ret = avio_open(&ofmt->pb, out_mp4, AVIO_FLAG_WRITE);
        if (ret < 0) { log_err("avio_open", ret); goto end_map; }
    }

    // Write header
    ret = avformat_write_header(ofmt, NULL);
    if (ret < 0) { log_err("write_header", ret); goto end_map; }

    // Remux loop
    AVPacket pkt;
    while (1) {
        ret = av_read_frame(ifmt, &pkt);
        if (ret < 0) break;

        int in_idx = pkt.stream_index;
        if (in_idx < 0 || in_idx >= (int)ifmt->nb_streams) {
            av_packet_unref(&pkt);
            continue;
        }

        int out_idx_mapped = stream_mapping[in_idx];
        if (out_idx_mapped < 0) {
            av_packet_unref(&pkt);
            continue;
        }

        AVStream *in_st  = ifmt->streams[in_idx];
        AVStream *out_st = ofmt->streams[out_idx_mapped];

        pkt.pts = av_rescale_q_rnd(pkt.pts, in_st->time_base, out_st->time_base,
                                   (enum AVRounding)(AV_ROUND_NEAR_INF | AV_ROUND_PASS_MINMAX));
        pkt.dts = av_rescale_q_rnd(pkt.dts, in_st->time_base, out_st->time_base,
                                   (enum AVRounding)(AV_ROUND_NEAR_INF | AV_ROUND_PASS_MINMAX));
        pkt.duration = av_rescale_q(pkt.duration, in_st->time_base, out_st->time_base);
        pkt.pos = -1;
        pkt.stream_index = out_idx_mapped;

        ret = av_interleaved_write_frame(ofmt, &pkt);
        av_packet_unref(&pkt);
        if (ret < 0) { log_err("write_frame", ret); break; }
    }

    av_write_trailer(ofmt);
    if (ret == AVERROR_EOF) ret = 0;

    end_map:
    if (stream_mapping) av_freep(&stream_mapping);

    end:
    if (ifmt) avformat_close_input(&ifmt);
    if (ofmt) {
        if (!(ofmt->oformat->flags & AVFMT_NOFILE) && ofmt->pb) avio_closep(&ofmt->pb);
        avformat_free_context(ofmt);
    }
    return ret < 0 ? ret : 0;
}


int remux_m3u8_to_mp4(const char *in_m3u8, const char *out_mp4) {
    ensure_ff_log_inited();

    if (!in_m3u8 || !out_mp4) return AVERROR(EINVAL);

    avformat_network_init();

    // 先 A+V
    int ret = remux_internal(in_m3u8, out_mp4, 0);
    if (ret == 0) {
        avformat_network_deinit();
        return 0;
    }

    // 失败兜底：video-only
    //（仍然失败就返回错误码）
    ret = remux_internal(in_m3u8, out_mp4, 1);

    avformat_network_deinit();
    return ret;
}