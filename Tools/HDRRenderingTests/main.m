// Decode synthetic color-tagged fixtures through the actual libmpv OpenGL backend.
#define GL_SILENCE_DEPRECATION
#import <AppKit/AppKit.h>
#include <OpenGL/CGLRenderers.h>
#include <OpenGL/gl3.h>
#include <dlfcn.h>
#include <limits.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <mpv/client.h>
#include <mpv/render_gl.h>

enum { WIDTH = 128, HEIGHT = 64, PIXEL_BYTES = WIDTH * HEIGHT * 4, GUARD_BYTES = 256 };
static mpv_handle *player;
static mpv_render_context *renderer;
static GLuint texture, framebuffer;
static atomic_bool pending;
static bool loaded, replied, suspend_draw, playback_ready;
static unsigned checks, frames;
static uint64_t request_id;
static int64_t integer_reply;
static char *string_reply;

static void require(bool condition, const char *message) {
  checks++;
  if (!condition) { fprintf(stderr, "FAIL: %s\n", message); exit(1); }
}

static void checked(int result, const char *message) {
  if (result < 0) fprintf(stderr, "libmpv: %s: %s\n", message, mpv_error_string(result));
  require(result >= 0, message);
}

static double now(void) {
  struct timespec value;
  require(clock_gettime(CLOCK_MONOTONIC, &value) == 0, "Read monotonic clock");
  return value.tv_sec + value.tv_nsec / 1e9;
}

static void update(void *context) {
  (void)context;
  atomic_store(&pending, true);
}

static void *get_proc(void *context, const char *name) { return dlsym(context, name); }

static void draw(void) {
  mpv_opengl_fbo target = {(int)framebuffer, WIDTH, HEIGHT, GL_RGBA8};
  int flip = 1, depth = 8, block = 0;
  mpv_render_param parameters[] = {
    {MPV_RENDER_PARAM_OPENGL_FBO, &target}, {MPV_RENDER_PARAM_FLIP_Y, &flip},
    {MPV_RENDER_PARAM_DEPTH, &depth}, {MPV_RENDER_PARAM_BLOCK_FOR_TARGET_TIME, &block},
    {MPV_RENDER_PARAM_INVALID, NULL}
  };
  checked(mpv_render_context_render(renderer, parameters), "Render through actual GPU LCMS backend");
  glFinish();
  require(glGetError() == GL_NO_ERROR, "OpenGL rendering has no error");
  mpv_render_context_report_swap(renderer);
  frames++;
}

static void pump(void) {
  if (atomic_exchange(&pending, false) && (mpv_render_context_update(renderer) & MPV_RENDER_UPDATE_FRAME)) {
    if (suspend_draw) atomic_store(&pending, true);
    else draw();
  }
  for (;;) {
    mpv_event *event = mpv_wait_event(player, 0);
    if (event->event_id == MPV_EVENT_NONE) break;
    if (event->event_id == MPV_EVENT_FILE_LOADED) loaded = true;
    if (event->event_id == MPV_EVENT_PLAYBACK_RESTART) playback_ready = true;
    if (event->event_id == MPV_EVENT_LOG_MESSAGE) {
      mpv_event_log_message *log = event->data;
      if (strstr(log->prefix, "libmpv_render") || strstr(log->prefix, "vd")) {
        printf("LCMS %s: %s", log->prefix, log->text);
      }
    }
    if (event->reply_userdata && event->reply_userdata == request_id) {
      checked(event->error, "Complete asynchronous core request");
      if (event->event_id == MPV_EVENT_GET_PROPERTY_REPLY) {
        mpv_event_property *property = event->data;
        require(property && property->data, "Read actual property");
        if (property->format == MPV_FORMAT_STRING) {
          free(string_reply);
          string_reply = strdup(*(char **)property->data);
        } else integer_reply = *(int64_t *)property->data;
      }
      replied = true;
    }
    if (event->event_id == MPV_EVENT_END_FILE) {
      mpv_event_end_file *end = event->data;
      require(end->reason != MPV_END_FILE_REASON_ERROR, "Decode generated color reference");
    }
    require(event->event_id != MPV_EVENT_SHUTDOWN, "The core remains alive");
  }
  struct timespec delay = {0, 1000000};
  nanosleep(&delay, NULL);
}

static void wait_reply(void) {
  double deadline = now() + 15;
  while (!replied && now() < deadline) pump();
  require(replied, "Core request completes within fifteen seconds");
}

static void set_auto(bool enabled) {
  int flag = enabled;
  unsigned previous_frames = frames;
  suspend_draw = true;
  replied = false;
  checked(mpv_set_property_async(player, ++request_id, "icc-profile-auto", MPV_FORMAT_FLAG, &flag),
          "Change ICC auto setting asynchronously");
  wait_reply();
  suspend_draw = false;
  require(frames == previous_frames, "ICC auto changes do not hide stale options behind an intermediate render");
  // Submit the profile immediately after this returns, exactly like the app.
}

static int64_t read_integer(const char *property) {
  replied = false;
  checked(mpv_get_property_async(player, ++request_id, property, MPV_FORMAT_INT64), property);
  wait_reply();
  return integer_reply;
}

static void submit_profile(NSData *profile, const char *label) {
  const size_t length = profile.length;
  require(length > 0 && length < 1024 * 1024, "Standard ICC data is nonempty and bounded");
  unsigned char *allocation = malloc(GUARD_BYTES + length + GUARD_BYTES);
  require(allocation != NULL, "Allocate caller-owned guarded ICC storage");
  memset(allocation, 0xA5, GUARD_BYTES + length + GUARD_BYTES);
  unsigned char *bytes = allocation + GUARD_BYTES;
  memcpy(bytes, profile.bytes, length);
  mpv_byte_array blob = {bytes, length};
  mpv_render_param parameter = {MPV_RENDER_PARAM_ICC_PROFILE, &blob};
  printf("ICC borrowed submit: %s (%zu bytes)\n", label, length);
  fflush(stdout);
  checked(mpv_render_context_set_parameter(renderer, parameter), "Accept a borrowed ICC byte array");
  require(blob.data == bytes && blob.size == length, "The parameter structure remains caller-owned and unchanged");
  require(memcmp(bytes, profile.bytes, length) == 0, "libmpv does not modify caller ICC bytes");
  for (size_t index = 0; index < GUARD_BYTES; index++) {
    require(allocation[index] == 0xA5 && allocation[GUARD_BYTES + length + index] == 0xA5,
            "Caller allocation guard bytes remain intact");
  }
  // The caller can immediately overwrite and free its bytes. Subsequent render,
  // duplicate comparison, replacement and destruction must use libmpv's copy.
  memset(allocation, 0x3C, GUARD_BYTES + length + GUARD_BYTES);
  free(allocation);
  memset(&blob, 0, sizeof(blob));
  draw();
  pump();
}

static void pixels(unsigned char *output) {
  glBindFramebuffer(GL_READ_FRAMEBUFFER, framebuffer);
  glReadBuffer(GL_COLOR_ATTACHMENT0);
  glReadPixels(0, 0, WIDTH, HEIGHT, GL_RGBA, GL_UNSIGNED_BYTE, output);
  glBindFramebuffer(GL_READ_FRAMEBUFFER, 0);
  require(glGetError() == GL_NO_ERROR, "Read actual color-transformed framebuffer pixels");
}

int main(int argc, const char **argv) {
  @autoreleasepool {
    require(argc == 5, "Usage: HDRRenderingTests EXPECTED_LIBMPV INPUT OUTPUT_PPM EXPECTED_GAMMA");
    Dl_info library_info;
    char expected[PATH_MAX], actual[PATH_MAX];
    require(realpath(argv[1], expected) != NULL && dladdr((void *)mpv_render_context_set_parameter, &library_info) != 0 &&
            realpath(library_info.dli_fname, actual) != NULL && strcmp(expected, actual) == 0,
            "The selected actual libmpv library is loaded");
    printf("LIBRARY: %s\n", actual);
    NSData *srgb = NSColorSpace.sRGBColorSpace.ICCProfileData;
    NSData *p3 = NSColorSpace.displayP3ColorSpace.ICCProfileData;
    require(srgb.length > 0 && p3.length > 0 && ![srgb isEqualToData:p3], "Use distinct genuine macOS sRGB and Display P3 profiles");

    const char *forced = getenv("CHENGYING_TEST_SOFTWARE_GL");
    require(!forced || strcmp(forced, "1") == 0, "CHENGYING_TEST_SOFTWARE_GL accepts only 1 when set");
    CGLPixelFormatAttribute accelerated[] = {kCGLPFAOpenGLProfile, (CGLPixelFormatAttribute)kCGLOGLPVersion_3_2_Core,
      kCGLPFAAccelerated, kCGLPFAAllowOfflineRenderers, 0};
    CGLPixelFormatAttribute software[] = {kCGLPFAOpenGLProfile, (CGLPixelFormatAttribute)kCGLOGLPVersion_3_2_Core,
      kCGLPFARendererID, (CGLPixelFormatAttribute)kCGLRendererGenericFloatID, 0};
    CGLPixelFormatObj format = NULL;
    CGLContextObj context = NULL;
    GLint count = 0;
    for (unsigned attempt = forced ? 1 : 0; attempt < 2; attempt++) {
      if (CGLChoosePixelFormat(attempt ? software : accelerated, &format, &count) == kCGLNoError && format &&
          CGLCreateContext(format, NULL, &context) == kCGLNoError && context && CGLSetCurrentContext(context) == kCGLNoError) break;
      if (context) { CGLSetCurrentContext(NULL); CGLReleaseContext(context); context = NULL; }
      if (format) { CGLReleasePixelFormat(format); format = NULL; }
    }
    require(context != NULL, "A real CGL renderer is mandatory; no skip or substitute backend is allowed");
    printf("OPENGL: %s\n", glGetString(GL_RENDERER));
    void *gl = dlopen("/System/Library/Frameworks/OpenGL.framework/OpenGL", RTLD_NOW | RTLD_LOCAL);
    require(gl != NULL, "Load system OpenGL entry points");
    player = mpv_create();
    require(player != NULL, "Create the actual libmpv core");
    const char *options[][2] = {{"config", "no"}, {"terminal", "no"}, {"vo", "libmpv"}, {"ao", "null"},
      {"hwdec", "no"}, {"idle", "yes"}, {"pause", "yes"}, {"keep-open", "yes"}, {"loop-file", "inf"},
      {"input-default-bindings", "no"}, {"input-terminal", "no"}, {"icc-profile-auto", "no"},
      {"video-timing-offset", "0"}, {"osd-level", "0"}, {"dither-depth", "no"}, {"deband", "no"}};
    for (size_t index = 0; index < sizeof(options) / sizeof(options[0]); index++) {
      checked(mpv_set_option_string(player, options[index][0], options[index][1]), options[index][0]);
    }
    checked(mpv_initialize(player), "Initialize actual libmpv");
    checked(mpv_request_log_messages(player, "v"), "Observe actual color-management diagnostics");
    mpv_opengl_init_params initialization = {get_proc, gl};
    int advanced = 1;
    mpv_render_param parameters[] = {{MPV_RENDER_PARAM_API_TYPE, MPV_RENDER_API_TYPE_OPENGL},
      {MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, &initialization}, {MPV_RENDER_PARAM_ADVANCED_CONTROL, &advanced}, {0, NULL}};
    checked(mpv_render_context_create(&renderer, player, parameters), "Create the actual OpenGL render backend");
    mpv_render_context_set_update_callback(renderer, update, NULL);
    glGenTextures(1, &texture);
    glBindTexture(GL_TEXTURE_2D, texture);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, WIDTH, HEIGHT, 0, GL_RGBA, GL_UNSIGNED_BYTE, NULL);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    glBindTexture(GL_TEXTURE_2D, 0);
    glGenFramebuffers(1, &framebuffer);
    glBindFramebuffer(GL_FRAMEBUFFER, framebuffer);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, texture, 0);
    require(glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE, "Create a complete isolated framebuffer");
    glBindFramebuffer(GL_FRAMEBUFFER, 0);

    set_auto(true);
    submit_profile(srgb, "isolated standard sRGB output");
    const char *load[] = {"loadfile", argv[2], "replace", NULL};
    replied = false;
    checked(mpv_command_async(player, ++request_id, load), "Load the selected local input");
    wait_reply();
    double deadline = now() + 15;
    while (!loaded && now() < deadline) pump();
    require(loaded, "Input reaches the real decoder");
    deadline = now() + 30;
    while (!playback_ready && now() < deadline) pump();
    require(playback_ready, "The synthetic fixture reaches a rendered frame");
    require(read_integer("width") == WIDTH && read_integer("height") == HEIGHT,
            "Actual decoder opened the complete synthetic fixture");
    for (unsigned index = 0; index < 5; index++) pump();
    const char *property_names[] = {"video-params/primaries", "video-params/gamma", "video-params/colormatrix",
      "video-params/sig-peak", "video-out-params", "hwdec-current"};
    for (unsigned index = 0; index < sizeof(property_names) / sizeof(property_names[0]); index++) {
      replied = false;
      checked(mpv_get_property_async(player, ++request_id, property_names[index], MPV_FORMAT_STRING), property_names[index]);
      wait_reply();
      printf("PROPERTY %s: %s\n", property_names[index], string_reply);
      if (!strcmp(property_names[index], "video-params/gamma")) {
        require(!strcmp(string_reply, argv[4]), "Decoder retains the fixture transfer metadata");
      }
    }
    draw();
    unsigned char output[PIXEL_BYTES];
    pixels(output);
    FILE *file = fopen(argv[3], "wbx");
    require(file != NULL, "Create a new isolated pixel reference");
    require(fprintf(file, "P6\n%d %d\n255\n", WIDTH, HEIGHT) > 0, "Write PPM header");
    double sums[3] = {0};
    unsigned clipped[3] = {0};
    for (size_t index = 0; index < PIXEL_BYTES; index += 4) {
      size_t row = index / (WIDTH * 4), column = (index / 4) % WIDTH;
      size_t top_down = ((HEIGHT - row - 1) * WIDTH + column) * 4;
      require(fwrite(output + top_down, 1, 3, file) == 3, "Write actual framebuffer pixel");
      for (unsigned channel = 0; channel < 3; channel++) {
        sums[channel] += output[index + channel];
        clipped[channel] += output[index + channel] >= 250;
      }
    }
    fclose(file);
    printf("PIXEL_STATS mean_R=%.3f mean_G=%.3f mean_B=%.3f clip_R=%.5f clip_G=%.5f clip_B=%.5f\n",
      sums[0]/(WIDTH*HEIGHT), sums[1]/(WIDTH*HEIGHT), sums[2]/(WIDTH*HEIGHT),
      (double)clipped[0]/(WIDTH*HEIGHT), (double)clipped[1]/(WIDTH*HEIGHT), (double)clipped[2]/(WIDTH*HEIGHT));
    replied = false;
    const char *stop[] = {"stop", NULL};
    checked(mpv_command_async(player, ++request_id, stop), "Stop the isolated decoder");
    wait_reply();
    mpv_render_context_set_update_callback(renderer, NULL, NULL);
    mpv_render_context_free(renderer);
    mpv_terminate_destroy(player);
    glDeleteFramebuffers(1, &framebuffer);
    glDeleteTextures(1, &texture);
    CGLSetCurrentContext(NULL);
    CGLReleaseContext(context);
    CGLReleasePixelFormat(format);
    dlclose(gl);
    printf("PASS: Actual HDR fixture rendering: %u checks, %u real renders; no GUI, user media or personal preferences.\n", checks, frames);
  }
  return 0;
}
