// Exercise the real pinned mp_image implementation with synthetic AVFrames.
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <libavutil/dovi_meta.h>
#include <libavutil/frame.h>
#include <libavutil/mastering_display_metadata.h>
#include <libavutil/mem.h>

#include "mpv_talloc.h"
#include "video/mp_image.h"

static unsigned checks;
void test_format_filter(void);

static void check(bool condition, const char *message)
{
    checks++;
    if (!condition) {
        fprintf(stderr, "FAIL: %s\n", message);
        exit(1);
    }
}

static AVFrame *make_frame(enum AVColorTransferCharacteristic transfer,
                           bool mastering_metadata)
{
    AVFrame *frame = av_frame_alloc();
    check(frame != NULL, "Allocate AVFrame");
    frame->format = AV_PIX_FMT_YUV420P10LE;
    frame->width = frame->height = 64;
    frame->sample_aspect_ratio = (AVRational){1, 1};
    frame->colorspace = AVCOL_SPC_BT2020_NCL;
    frame->color_primaries = AVCOL_PRI_BT2020;
    frame->color_trc = transfer;
    frame->color_range = AVCOL_RANGE_MPEG;
    check(av_frame_get_buffer(frame, 64) >= 0, "Allocate synthetic frame pixels");
    if (mastering_metadata) {
        AVMasteringDisplayMetadata *mdm =
            av_mastering_display_metadata_create_side_data(frame);
        check(mdm != NULL, "Allocate mastering metadata");
        mdm->has_luminance = 1;
        mdm->min_luminance = (AVRational){1, 200};
        mdm->max_luminance = (AVRational){1200, 1};
        AVContentLightMetadata *clm = av_content_light_metadata_create_side_data(frame);
        check(clm != NULL, "Allocate content light metadata");
        clm->MaxCLL = 1400;
        clm->MaxFALL = 350;
    }
    return frame;
}

static void add_dovi(AVFrame *frame)
{
    size_t size = 0;
    AVDOVIMetadata *metadata = av_dovi_metadata_alloc(&size);
    check(metadata != NULL, "Allocate synthetic Dolby Vision metadata");
    AVDOVIRpuDataHeader *header = av_dovi_get_header(metadata);
    header->disable_residual_flag = 1;
    header->bl_bit_depth = header->vdr_bit_depth = 10;
    header->coef_log2_denom = 23;
    AVDOVIDataMapping *mapping = av_dovi_get_mapping(metadata);
    for (int channel = 0; channel < 3; channel++) {
        AVDOVIReshapingCurve *curve = &mapping->curves[channel];
        curve->num_pivots = 2;
        curve->pivots[1] = 1023;
        curve->poly_order[0] = 1;
        curve->poly_coef[0][1] = 1 << 23;
    }
    AVDOVIColorMetadata *color = av_dovi_get_color(metadata);
    for (int i = 0; i < 9; i++) {
        color->ycc_to_rgb_matrix[i] = (AVRational){i % 4 == 0, 1};
        color->rgb_to_lms_matrix[i] = (AVRational){i % 4 == 0, 1};
    }
    for (int i = 0; i < 3; i++)
        color->ycc_to_rgb_offset[i] = (AVRational){0, 1};
    color->source_min_pq = 40;
    color->source_max_pq = 4095;
    AVFrameSideData *side = av_frame_new_side_data(frame, AV_FRAME_DATA_DOVI_METADATA, size);
    check(side != NULL, "Attach synthetic Dolby Vision metadata");
    memcpy(side->data, metadata, size);
    av_free(metadata);
}

static void restore(struct mp_image_params *params)
{
#if HAVE_DOVI_FALLBACK
    mp_image_params_restore_dovi_mapping(params);
#else
    // Original GL init passes the mapped params directly to guess_csp.
    (void)params;
#endif
    mp_image_params_guess_csp(params);
}

static void assert_base(const struct mp_image_params *actual,
                         const struct mp_image_params *expected)
{
    check(actual->color.transfer == expected->color.transfer,
          "Fallback restores the base-layer transfer function");
    check(actual->color.primaries == expected->color.primaries &&
          actual->repr.sys == expected->repr.sys,
          "Fallback restores the base-layer primaries and matrix");
    check(actual->light == expected->light,
          "Fallback restores the base-layer light model after decoder inference");
    check(pl_color_space_equal(&actual->color, &expected->color),
          "Fallback retains base-layer HDR metadata without Dolby Vision peaks");
    check(actual->repr.dovi == NULL, "Fallback clears the unused Dolby Vision mapping");
}

static void test_mapping(enum AVColorTransferCharacteristic transfer, bool mastering)
{
    AVFrame *base = make_frame(transfer, mastering);
    AVFrame *encoded = av_frame_clone(base);
    check(encoded != NULL, "Clone base-layer frame");
    add_dovi(encoded);
    struct mp_image *reference = mp_image_from_av_frame(base);
    struct mp_image *mapped = mp_image_from_av_frame(encoded);
    check(reference != NULL && mapped != NULL, "Convert synthetic AVFrames using real mpv");
    check(mapped->params.repr.sys == PL_COLOR_SYSTEM_DOLBYVISION &&
          mapped->params.color.transfer == PL_COLOR_TRC_PQ && mapped->dovi != NULL,
          "Pinned libplacebo actually maps the synthetic Dolby Vision metadata");
    mp_image_params_guess_csp(&reference->params);
    // The decoder performs inference before the GL renderer sees the frame.
    mp_image_params_guess_csp(&mapped->params);
    check(mapped->params.light == MP_CSP_LIGHT_DISPLAY,
          "Mapped PQ frame reproduces the decoder's display-light inference");
    struct mp_image_params fallback = mapped->params;
    restore(&fallback);
    assert_base(&fallback, &reference->params);

    struct mp_image *copied = mp_image_alloc(mapped->imgfmt, mapped->w, mapped->h);
    check(copied != NULL, "Allocate attribute-copy destination");
    mp_image_copy_attributes(copied, mapped);
    restore(&copied->params);
    assert_base(&copied->params, &reference->params);

    AVFrame *roundtrip = mp_image_to_av_frame(mapped);
    check(roundtrip != NULL, "Convert mapped image back to AVFrame");
    check(roundtrip->color_trc == base->color_trc &&
          roundtrip->color_primaries == base->color_primaries &&
          roundtrip->colorspace == base->colorspace,
          "AVFrame round-trip uses base-layer color tags");
    check(av_frame_get_side_data(roundtrip, AV_FRAME_DATA_DOVI_METADATA) != NULL,
          "AVFrame round-trip preserves Dolby Vision side data");
    check(mapped->params.repr.sys == PL_COLOR_SYSTEM_DOLBYVISION,
          "AVFrame conversion does not mutate the source image");
    struct mp_image *again = mp_image_from_av_frame(roundtrip);
    check(again != NULL && again->params.repr.sys == PL_COLOR_SYSTEM_DOLBYVISION,
          "AVFrame round-trip can map Dolby Vision again");
    mp_image_params_guess_csp(&again->params);
    restore(&again->params);
    assert_base(&again->params, &reference->params);

#if HAVE_DOVI_FALLBACK
    struct mp_image_params changed = mapped->params;
    changed.transfer_orig = transfer == AVCOL_TRC_ARIB_STD_B67 ?
        PL_COLOR_TRC_PQ : PL_COLOR_TRC_HLG;
    check(!mp_image_params_static_equal(&changed, &mapped->params),
          "A changed base-layer transfer triggers renderer reconfiguration");
    changed = mapped->params;
    changed.hdr_orig.max_luma += 1000;
    check(!mp_image_params_static_equal(&changed, &mapped->params),
          "Changed base-layer mastering metadata triggers renderer reconfiguration");
    changed = mapped->params;
    changed.hdr_orig.scene_avg += 20;
    changed.hdr_orig.scene_max[0] += 100;
    changed.hdr_orig.max_pq_y += 0.1;
    changed.hdr_orig.avg_pq_y += 0.1;
    changed.hdr_orig.ootf.target_luma += 100;
    check(!mp_image_params_equal(&changed, &mapped->params),
          "Full image equality retains dynamic base-layer HDR metadata");
    check(mp_image_params_static_equal(&changed, &mapped->params),
          "Dynamic base-layer HDR metadata does not reconfigure the renderer");
#endif
    talloc_free(again);
    talloc_free(copied);
    talloc_free(mapped);
    talloc_free(reference);
    av_frame_free(&roundtrip);
    av_frame_free(&encoded);
    av_frame_free(&base);
}

static void test_plain(enum AVColorTransferCharacteristic transfer)
{
    AVFrame *frame = make_frame(transfer, true);
    struct mp_image *image = mp_image_from_av_frame(frame);
    check(image != NULL, "Convert plain frame");
    mp_image_params_guess_csp(&image->params);
    struct mp_image_params expected = image->params;
    restore(&image->params);
    check(mp_image_params_equal(&image->params, &expected),
          "Plain SDR, HLG and PQ frames retain their color parameters");
    talloc_free(image);
    av_frame_free(&frame);
}

int main(void)
{
    test_mapping(AVCOL_TRC_ARIB_STD_B67, false);
    test_mapping(AVCOL_TRC_ARIB_STD_B67, true);
    test_mapping(AVCOL_TRC_SMPTE2084, true);
    test_mapping(AVCOL_TRC_BT709, false);
    test_plain(AVCOL_TRC_ARIB_STD_B67);
    test_plain(AVCOL_TRC_SMPTE2084);
    test_plain(AVCOL_TRC_BT709);
    test_format_filter();
    printf("PASS: %u synthetic AVFrame Dolby Vision fallback checks\n", checks);
    return 0;
}
