#define _POSIX_C_SOURCE 200809L
#include <VideoToolbox/VideoToolbox.h>
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/pixdesc.h>
#include <mpv/client.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static char decoder_log[65536];
static size_t decoder_log_size;

static void capture_log(const mpv_event *event) {
    if (event->event_id != MPV_EVENT_LOG_MESSAGE || decoder_log_size >= sizeof(decoder_log) - 1)
        return;
    const mpv_event_log_message *message = event->data;
    size_t available = sizeof(decoder_log) - decoder_log_size;
    int written = snprintf(decoder_log + decoder_log_size, available, "[%s/%s] %s",
                           message->prefix, message->level, message->text);
    if (written > 0)
        decoder_log_size += (size_t)written < available ? (size_t)written : available - 1;
}

static void require(bool condition, const char *message) {
    if (!condition) {
        fprintf(stderr, "FAIL: %s\n", message);
        if (decoder_log_size)
            fprintf(stderr, "BEGIN BOUNDED SYNTHETIC DECODER LOG\n%s\nEND DECODER LOG\n", decoder_log);
        exit(1);
    }
}

static double now(void) {
    struct timespec value;
    require(clock_gettime(CLOCK_MONOTONIC, &value) == 0, "Monotonic clock");
    return value.tv_sec + value.tv_nsec / 1000000000.0;
}

static void drain_diagnostic_logs(mpv_handle *player) {
    // mpv gives queued playback events priority over its separate log buffer.
    // Drain already-produced diagnostics before asserting the active decoder.
    const double deadline = now() + 0.05;
    for (int i = 0; i < 512 && now() < deadline; ++i) {
        mpv_event *event = mpv_wait_event(player, 0);
        if (event->event_id == MPV_EVENT_NONE) break;
        capture_log(event);
    }
}

static void check_backend(void) {
    const AVCodec *codec = avcodec_find_decoder_by_name("av1");
    require(codec != NULL, "Native AV1 decoder is present");
    bool found = false;
    for (int i = 0;; ++i) {
        const AVCodecHWConfig *config = avcodec_get_hw_config(codec, i);
        if (!config) break;
        if (config->device_type == AV_HWDEVICE_TYPE_VIDEOTOOLBOX &&
            config->pix_fmt == AV_PIX_FMT_VIDEOTOOLBOX) found = true;
    }
    require(found, "Native AV1 decoder advertises VideoToolbox support");
    require(avcodec_find_decoder_by_name("libdav1d") != NULL,
            "Pinned dav1d software fallback remains present");
    printf("PASS: Actual libavcodec AV1 VideoToolbox configuration and dav1d fallback\n");
}

static void receive_frames(AVCodecContext *decoder, AVFrame *frame,
                           int expected_depth, int *count) {
    int result;
    while ((result = avcodec_receive_frame(decoder, frame)) >= 0) {
        const AVPixFmtDescriptor *format = av_pix_fmt_desc_get(frame->format);
        require(frame->width == 192 && frame->height == 108, "AV1 display dimensions");
        require(format && format->comp[0].depth == expected_depth, "AV1 decoded bit depth");
        require(frame->data[0] && frame->linesize[0] > 0, "AV1 decoded pixel buffer");
        ++*count;
        av_frame_unref(frame);
    }
    require(result == AVERROR(EAGAIN) || result == AVERROR_EOF, "AV1 frame decode");
}

static void decode_fixture(const char *path, int depth) {
    AVFormatContext *format = NULL;
    require(avformat_open_input(&format, path, NULL, NULL) >= 0, "Open synthetic AV1 fixture");
    require(avformat_find_stream_info(format, NULL) >= 0, "Find AV1 stream");
    int stream = av_find_best_stream(format, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0);
    require(stream >= 0, "AV1 video stream");
    const AVCodec *codec = avcodec_find_decoder_by_name("libdav1d");
    AVCodecContext *decoder = avcodec_alloc_context3(codec);
    require(decoder != NULL, "Allocate dav1d context");
    require(avcodec_parameters_to_context(decoder, format->streams[stream]->codecpar) >= 0,
            "Copy AV1 stream parameters");
    decoder->thread_count = 2;
    require(avcodec_open2(decoder, codec, NULL) >= 0, "Open pinned dav1d decoder");
    AVFrame *frame = av_frame_alloc();
    AVPacket *packet = av_packet_alloc();
    require(frame && packet, "Allocate AV1 frame and packet");
    int count = 0, result;
    while ((result = av_read_frame(format, packet)) >= 0) {
        if (packet->stream_index == stream) {
            require(avcodec_send_packet(decoder, packet) >= 0, "Send AV1 packet");
            receive_frames(decoder, frame, depth, &count);
        }
        av_packet_unref(packet);
    }
    require(result == AVERROR_EOF, "Read complete AV1 fixture");
    require(avcodec_send_packet(decoder, NULL) >= 0, "Flush AV1 decoder");
    receive_frames(decoder, frame, depth, &count);
    require(count == 24, "Decode all 24 synthetic AV1 frames");
    av_packet_free(&packet);
    av_frame_free(&frame);
    avcodec_free_context(&decoder);
    avformat_close_input(&format);
    printf("PASS: Actual dav1d decoded all 24 AV1 %d-bit frames at 192x108\n", depth);
}

static void option(mpv_handle *player, const char *name, const char *value) {
    int result = mpv_set_option_string(player, name, value);
    if (result < 0) fprintf(stderr, "Option %s: %s\n", name, mpv_error_string(result));
    require(result >= 0, "Set isolated mpv option");
}

static void wait_event(mpv_handle *player, mpv_event_id expected) {
    double deadline = now() + 15;
    while (now() < deadline) {
        mpv_event *event = mpv_wait_event(player, 0.1);
        capture_log(event);
        if (event->event_id == expected) return;
        if (event->event_id == MPV_EVENT_END_FILE) {
            mpv_event_end_file *end = event->data;
            if (end->reason == MPV_END_FILE_REASON_ERROR)
                fprintf(stderr, "Playback error: %s\n", mpv_error_string(end->error));
            require(end->reason != MPV_END_FILE_REASON_ERROR, "AV1 playback did not fail");
        }
    }
    fprintf(stderr, "Missing event: %s\n", mpv_event_name(expected));
    require(false, "Bounded mpv event deadline");
}

static void play_fixture(const char *path, int depth, const char *mode, bool hardware) {
    decoder_log_size = 0;
    decoder_log[0] = '\0';
    mpv_handle *player = mpv_create();
    require(player != NULL, "Create isolated mpv player");
    option(player, "config", "no");
    option(player, "vo", "null");
    option(player, "ao", "null");
    option(player, "audio", "no");
    option(player, "idle", "yes");
    option(player, "keep-open", "yes");
    option(player, "pause", "yes");
    option(player, "hwdec", mode);
    option(player, "hwdec-codecs", "av1");
    option(player, "vd-lavc-threads", "2");
    require(mpv_request_log_messages(player, "v") >= 0, "Enable bounded decoder diagnostics");
    require(mpv_initialize(player) >= 0, "Initialize actual libmpv");
    const char *load[] = {"loadfile", path, "replace", NULL};
    require(mpv_command(player, load) >= 0, "Load synthetic AV1 fixture");
    wait_event(player, MPV_EVENT_FILE_LOADED);
    wait_event(player, MPV_EVENT_PLAYBACK_RESTART);
    char *active = mpv_get_property_string(player, "hwdec-current");
    require(active != NULL, "Read actual AV1 decoder path");
    char *decoder = mpv_get_property_string(player, "current-tracks/video/decoder-desc");
    char *pixel_format = mpv_get_property_string(player, "video-dec-params/pixelformat");
    printf("INFO: AV1 %d-bit requested=%s active=%s decoder=%s pixel-format=%s\n",
           depth, mode, active, decoder ? decoder : "unavailable",
           pixel_format ? pixel_format : "unavailable");
    fflush(stdout);
    mpv_free(decoder);
    mpv_free(pixel_format);
    drain_diagnostic_logs(player);
    if (strcmp(mode, "no") == 0 || !hardware) {
        require(strcmp(active, "no") == 0, "Software AV1 fallback is actually selected");
    } else {
        require(strcmp(active, "videotoolbox-copy") == 0,
                "Hardware-capable AV1 host actually uses VideoToolbox copy decode");
    }
    int64_t width = 0, height = 0;
    require(mpv_get_property(player, "video-params/w", MPV_FORMAT_INT64, &width) >= 0 &&
            mpv_get_property(player, "video-params/h", MPV_FORMAT_INT64, &height) >= 0 &&
            width == 192 && height == 108, "libmpv decoded AV1 dimensions");
    printf("PASS: Actual libmpv AV1 %d-bit requested=%s active=%s\n", depth, mode, active);
    mpv_free(active);
    for (int i = 0; i < 4; ++i) {
        const char *seek[] = {"seek", i % 2 ? "0.25" : "1.25", "absolute+exact", NULL};
        require(mpv_command(player, seek) >= 0, "AV1 exact seek");
        wait_event(player, MPV_EVENT_PLAYBACK_RESTART);
        double position = 0;
        require(mpv_get_property(player, "time-pos", MPV_FORMAT_DOUBLE, &position) >= 0 &&
                position >= (i % 2 ? 0.24 : 1.24) && position <= (i % 2 ? 0.35 : 1.35),
                "AV1 seek reached requested frame interval");
    }
    int paused = 0;
    require(mpv_set_property(player, "pause", MPV_FORMAT_FLAG, &paused) >= 0, "Resume AV1 playback");
    double deadline = now() + 10;
    int eof = 0;
    while (!eof && now() < deadline) {
        mpv_event *event = mpv_wait_event(player, 0.1);
        capture_log(event);
        if (event->event_id == MPV_EVENT_END_FILE) {
            mpv_event_end_file *end = event->data;
            require(end->reason != MPV_END_FILE_REASON_ERROR, "AV1 complete playback has no error");
        }
        mpv_get_property(player, "eof-reached", MPV_FORMAT_FLAG, &eof);
    }
    require(eof, "Bounded AV1 full playback reached EOF");
    mpv_terminate_destroy(player);
    printf("PASS: AV1 %d-bit %s four exact seeks, EOF, and decoder teardown\n", depth, mode);
}

int main(int argc, char **argv) {
    require(argc == 3, "Two synthetic AV1 fixtures are required");
    check_backend();
    bool hardware = VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1);
    printf("INFO: AV1 VideoToolbox hardware capability=%s\n", hardware ? "yes" : "no");
    for (int i = 0; i < 2; ++i) {
        int depth = i ? 10 : 8;
        decode_fixture(argv[i + 1], depth);
        play_fixture(argv[i + 1], depth, "no", hardware);
        play_fixture(argv[i + 1], depth, "videotoolbox-copy", hardware);
    }
    if (!hardware)
        puts("LIMIT: AV1 hardware decode cannot be validated on this host; real software fallback passed.");
    puts("PASS: AV1 playback regression suite (headless decoder path, not display/HDR quality)");
    return 0;
}
