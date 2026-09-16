#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <mpv/client.h>
#include <libavcodec/avcodec.h>
#include <libavfilter/avfilter.h>
#include <libavformat/avformat.h>
#include <libavutil/hwcontext.h>

static void require(int condition, const char *message) {
  if (!condition) {
    fprintf(stderr, "FAIL: %s\n", message);
    exit(1);
  }
}

int main(int argc, char **argv) {
  require(argc == 2, "Expected the extracted production initialization options");
  require((avcodec_version() >> 16) == 61, "Playback must retain FFmpeg 61 ABI");
  require((mpv_client_api_version() >> 16) == 2, "Playback must retain libmpv 2 ABI");
  const char *configuration = avcodec_configuration();
  const char *features[] = {"--enable-libdav1d", "--enable-libass", "--enable-libzimg",
    "--enable-videotoolbox", "--enable-audiotoolbox", "--enable-securetransport", "--disable-autodetect"};
  for (size_t i = 0; i < sizeof(features) / sizeof(features[0]); i++)
    require(strstr(configuration, features[i]) != NULL, features[i]);
  const char *decoders[] = {"h264", "hevc", "libdav1d", "vp9", "mpeg4", "prores", "aac", "alac", "flac", "opus"};
  for (size_t i = 0; i < sizeof(decoders) / sizeof(decoders[0]); i++)
    require(avcodec_find_decoder_by_name(decoders[i]) != NULL, decoders[i]);
  const char *filters[] = {"subtitles", "ass", "transpose", "zscale", "tonemap"};
  for (size_t i = 0; i < sizeof(filters) / sizeof(filters[0]); i++)
    require(avfilter_get_by_name(filters[i]) != NULL, filters[i]);
  require(av_hwdevice_find_type_by_name("videotoolbox") != AV_HWDEVICE_TYPE_NONE,
    "VideoToolbox hardware device support is missing");
  void *protocol_iterator = NULL;
  const char *protocol;
  int has_https = 0;
  while ((protocol = avio_enum_protocols(&protocol_iterator, 0)))
    if (strcmp(protocol, "https") == 0) has_https = 1;
  require(has_https, "HTTPS input is missing");

  mpv_handle *mpv = mpv_create();
  require(mpv != NULL, "Create source-built libmpv");
  FILE *production = fopen(argv[1], "r");
  require(production != NULL, "Open extracted production options");
  char line[2048];
  int option_count = 0;
  int literal_count = 0;
  while (fgets(line, sizeof(line), production)) {
    char *separator = strchr(line, '\t');
    require(separator != NULL, "Parse production option record");
    *separator++ = 0;
    char *value = strchr(separator, '\t');
    require(value != NULL, "Parse production literal marker");
    *value++ = 0;
    value[strcspn(value, "\r\n")] = 0;
    if (strcmp(separator, "1") == 0) {
      require(mpv_set_option_string(mpv, line, value) >= 0, line);
      literal_count++;
    }
    option_count++;
  }
  require(option_count >= 40, "Production initialization option coverage");
  require(mpv_set_option_string(mpv, "config", "no") >= 0, "Disable user configuration");
  require(mpv_set_option_string(mpv, "vo", "null") >= 0, "Set test video output");
  require(mpv_set_option_string(mpv, "ao", "null") >= 0, "Set test audio output");
  require(mpv_set_option_string(mpv, "terminal", "no") >= 0, "Disable terminal output");
  require(mpv_set_option_string(mpv, "idle", "yes") >= 0, "Enable idle test core");
  require(mpv_initialize(mpv) >= 0, "Initialize source-built libmpv");
  rewind(production);
  while (fgets(line, sizeof(line), production)) {
    *strchr(line, '\t') = 0;
    char property[2200];
    snprintf(property, sizeof(property), "option-info/%s/type", line);
    char *type = mpv_get_property_string(mpv, property);
    require(type != NULL, line);
    mpv_free(type);
  }
  fclose(production);
  printf("PASS: %d actual production initialization option names and %d literal values\n", option_count, literal_count);
  const char *options[] = {"video-zoom", "video-pan-x", "video-pan-y", "icc-profile",
    "tone-mapping", "target-trc", "sub-codepage", "screenshot-sw", "audio-pitch-correction"};
  for (size_t i = 0; i < sizeof(options) / sizeof(options[0]); i++) {
    char property[128];
    snprintf(property, sizeof(property), "options/%s", options[i]);
    char *value = mpv_get_property_string(mpv, property);
    require(value != NULL, options[i]);
    mpv_free(value);
  }
  char *version = mpv_get_property_string(mpv, "mpv-version");
  require(version && strstr(version, "0.38.0"), "Verify locked libmpv version");
  printf("PASS: Source-built %s / FFmpeg %s: native playback, codecs, HDR/ICC, subtitles, HTTPS, and viewport options\n",
    version, av_version_info());
  mpv_free(version);
  mpv_terminate_destroy(mpv);
  return 0;
}
