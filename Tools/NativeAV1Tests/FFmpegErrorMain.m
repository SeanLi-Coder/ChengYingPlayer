static int checks, failures;
static void check(BOOL condition, const char *label) {
    checks++;
    if (!condition) { failures++; fprintf(stderr, "FAIL %s\n", label); }
}
static enum AVPixelFormat countedFormat(AVCodecContext *context, const enum AVPixelFormat *formats) {
    formatCalls++;
    return CYNVideoFormat(context, formats);
}
int main(void) { @autoreleasepool {
    const FFHWAccel accel = {{"av1_videotoolbox"}};
    const AVCodecHWConfigInternal config = {{AV_PIX_FMT_VIDEOTOOLBOX, AV_CODEC_HW_CONFIG_METHOD_HW_DEVICE_CTX, 1}, &accel};
    const AVCodecHWConfigInternal *configs[] = {&config, NULL};
    const AVCodec codec = {configs};
    AVHWDeviceContext device = {1}; AVBufferRef deviceRef = {&device};
    enum AVPixelFormat choices[] = {AV_PIX_FMT_VIDEOTOOLBOX, AV_PIX_FMT_YUV420P, AV_PIX_FMT_NONE};
    int errors[] = {AVERROR(ENOMEM), AVERROR_EXIT, AVERROR(ENOSYS), 0};
    for (int i = 0; i < 4; ++i) {
        RetryBoundary *retry = [RetryBoundary new];
        retry->_av1Bootstrap.active = YES;
        AVCodecContext ctx = {.codec_id = AV_CODEC_ID_AV1, .opaque = &retry->_av1Bootstrap,
            .hw_device_ctx = &deviceRef, .codec = &codec, .get_format = countedFormat};
        initResult = errors[i]; formatCalls = initCalls = uninitCalls = 0;
        int result = ff_get_format(&ctx, choices);
        check(initCalls == 1, "AV1 hardware initialization occurs exactly once");
        if (i < 2) {
            check(result == AV_PIX_FMT_NONE, "AV1 resource/exit failure returns no format");
            check(formatCalls == 1, "AV1 resource/exit does not remove VT and retry callback");
            check(!retry->_av1Bootstrap.initializationRejected, "Resource/exit does not become availability rejection");
            // AV1 get_pixel_format may generalize the error. The actual CYN
            // retry predicate must still fail closed after that generalization.
            check(![retry canRetryAV1Initialization:AVERROR(EINVAL)], "CYN does not retry generalized resource/exit failure");
        } else if (i == 2) {
            check(result == AV_PIX_FMT_NONE && formatCalls == 2, "Availability failure retries callback without VT");
            check(retry->_av1Bootstrap.initializationRejected, "Availability rejection is explicitly observed");
            check([retry canRetryAV1Initialization:AVERROR(EINVAL)], "CYN can use software for observed availability failure");
            atomic_store(&retry->_input.cancelled, true);
            check(![retry canRetryAV1Initialization:AVERROR(EINVAL)], "Cancellation overrides observed availability");
            atomic_store(&retry->_input.cancelled, false);
            retry->_av1ProducedVideo = YES;
            check(![retry canRetryAV1Initialization:AVERROR(EINVAL)], "Post-first-frame failure cannot replay bootstrap");
        } else {
            check(result == AV_PIX_FMT_VIDEOTOOLBOX && formatCalls == 1, "Successful setup selects VT once");
            check(!retry->_av1Bootstrap.initializationRejected, "Successful setup does not imply rejection");
        }
    }
    for (int i = 0; i < 2; ++i) {
        AVCodecContext ctx = {.codec_id = AV_CODEC_ID_H264, .hw_device_ctx = &deviceRef,
            .codec = &codec, .get_format = countedFormat};
        initResult = errors[i]; formatCalls = initCalls = 0;
        check(ff_get_format(&ctx, choices) == AV_PIX_FMT_YUV420P, "Unrelated H264 format fallback remains unchanged");
        check(formatCalls == 2 && initCalls == 1, "H264 retains original callback retry semantics");
    }
    AVFrame frame = {42}; uint8_t bytes[] = {11, 22, 33};
    TestOBU units[] = {{&bytes[0], 1}, {&bytes[1], 1}, {&bytes[2], 1}};
    AV1DecContext av1 = {.cur_frame = {&frame}, .start_unit = 0, .nb_unit = 3, .current_obu = {units}};
    VTContext vt = {0}; AVCodecInternal internal = {&vt};
    AVCodecContext ctx = {.priv_data = &av1, .internal = &internal};
    for (int fail = 0; fail <= 3; ++fail) {
        appendCalls = commonCalls = 0; appendFailAt = fail; submittedFrame = NULL;
        vt.bitstream_size = 7;
        int result = videotoolbox_av1_end_frame(&ctx);
        if (fail) {
            check(result == AVERROR(ENOMEM), "AV1 OBU append propagates ENOMEM");
            check(commonCalls == 0 && submittedFrame == NULL, "Truncated AV1 bitstream is never submitted");
            check(appendCalls == fail && vt.bitstream_size == fail - 1, "Append failure stops at the exact failing OBU");
        } else {
            check(result == 23 && commonCalls == 1 && submittedFrame == &frame, "Complete AV1 bitstream is submitted once");
            check(appendCalls == 3 && vt.bitstream_size == 3 && memcmp(vt.bytes, bytes, 3) == 0, "OBU ordering and frame reset are preserved");
        }
    }
    fprintf(stdout, "FFmpeg resource boundary: %d checks, %d failures\n", checks, failures);
    return failures ? 1 : 0;
} }
