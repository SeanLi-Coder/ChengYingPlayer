// Exercise borrowed ICC buffers through the actual libmpv OpenGL backend.
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

enum { WIDTH = 64, HEIGHT = 64, PIXEL_BYTES = WIDTH * HEIGHT * 4, GUARD_BYTES = 256 };
static mpv_handle *player;
static mpv_render_context *renderer;
static GLuint texture, framebuffer;
static atomic_bool pending;
static bool loaded, replied, suspend_draw;
static unsigned checks, frames;
static uint64_t request_id;
static int64_t integer_reply;

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
    if (event->event_id == MPV_EVENT_LOG_MESSAGE) {
      mpv_event_log_message *log = event->data;
      if (strstr(log->prefix, "libmpv_render") &&
          (strstr(log->text, "ICC") || strstr(log->text, "icc") || strstr(log->text, "3D LUT"))) {
        printf("LCMS %s: %s", log->prefix, log->text);
      }
    }
    if (event->reply_userdata && event->reply_userdata == request_id) {
      checked(event->error, "Complete asynchronous core request");
      if (event->event_id == MPV_EVENT_GET_PROPERTY_REPLY) {
        mpv_event_property *property = event->data;
        require(property && property->format == MPV_FORMAT_INT64 && property->data,
                "Read actual decoded image dimensions");
        integer_reply = *(int64_t *)property->data;
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

static void clear_profile(void) {
  mpv_byte_array empty = {NULL, 0};
  mpv_render_param parameter = {MPV_RENDER_PARAM_ICC_PROFILE, &empty};
  checked(mpv_render_context_set_parameter(renderer, parameter), "Clear the active ICC profile");
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

static unsigned pixel_difference(const unsigned char *first, const unsigned char *second) {
  unsigned difference = 0;
  for (size_t index = 0; index < PIXEL_BYTES; index++) {
    if (index % 4 != 3) difference += (unsigned)abs((int)first[index] - second[index]);
  }
  return difference;
}

static void make_reference(const char *path) {
  FILE *file = fopen(path, "wbx");
  require(file != NULL, "Create only a new isolated color reference");
  require(fprintf(file, "P6\n%d %d\n255\n", WIDTH, HEIGHT) > 0, "Write PPM header");
  const unsigned char colors[4][3] = {{190, 80, 40}, {40, 160, 90}, {60, 70, 200}, {120, 120, 120}};
  for (unsigned row = 0; row < HEIGHT; row++) {
    for (unsigned column = 0; column < WIDTH; column++) {
      unsigned color = (row >= HEIGHT / 2 ? 2 : 0) + (column >= WIDTH / 2 ? 1 : 0);
      require(fwrite(colors[color], 1, 3, file) == 3, "Write generated reference pixel");
    }
  }
  require(fclose(file) == 0, "Finish the isolated reference");
}

int main(int argc, const char **argv) {
  @autoreleasepool {
    require(argc == 3, "Usage: ICCProfileTests EXPECTED_LIBMPV NEW_REFERENCE_PPM");
    Dl_info library_info;
    char expected[PATH_MAX], actual[PATH_MAX];
    require(realpath(argv[1], expected) != NULL && dladdr((void *)mpv_render_context_set_parameter, &library_info) != 0 &&
            realpath(library_info.dli_fname, actual) != NULL && strcmp(expected, actual) == 0,
            "The selected actual libmpv library is loaded");
    printf("LIBRARY: %s\n", actual);
    NSData *srgb = NSColorSpace.sRGBColorSpace.ICCProfileData;
    NSData *p3 = NSColorSpace.displayP3ColorSpace.ICCProfileData;
    require(srgb.length > 0 && p3.length > 0 && ![srgb isEqualToData:p3], "Use distinct genuine macOS sRGB and Display P3 profiles");
    make_reference(argv[2]);
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

    // The unpatched 0.38 API aborts here before any user media or window is involved.
    submit_profile(srgb, "auto disabled");
    const char *load[] = {"loadfile", argv[2], "replace", NULL};
    replied = false;
    checked(mpv_command_async(player, ++request_id, load), "Load only the generated PPM reference");
    wait_reply();
    double deadline = now() + 15;
    while (!loaded && now() < deadline) pump();
    require(loaded, "Generated reference reaches the real decoder");
    require(read_integer("width") == WIDTH && read_integer("height") == HEIGHT,
            "The actual decoder opened the generated 64x64 reference");
    for (unsigned index = 0; index < 20; index++) pump();
    draw();
    unsigned char unmanaged[PIXEL_BYTES], srgb_pixels[PIXEL_BYTES], p3_pixels[PIXEL_BYTES], repeated[PIXEL_BYTES];
    pixels(unmanaged);
    unsigned color_variation = 0;
    for (size_t index = 0; index < PIXEL_BYTES; index += 4) {
      color_variation += (unsigned)abs((int)unmanaged[index] - unmanaged[index + 1]);
    }
    require(color_variation > 0, "The unmanaged framebuffer contains actual colored reference pixels, not blank output");
    set_auto(true);
    submit_profile(p3, "auto enabled Display P3 without an intermediate render");
    pixels(p3_pixels);
    unsigned initial_change = pixel_difference(unmanaged, p3_pixels);
    printf("ICC PIXEL DIFFERENCE unmanaged_to_first_P3=%u\n", initial_change);
    require(initial_change > 0,
            "The first profile immediately after enabling auto actually transforms pixels");
    submit_profile(p3, "repeat identical P3 after caller storage was freed");
    pixels(repeated);
    require(pixel_difference(p3_pixels, repeated) == 0, "Repeated identical profile preserves exact output pixels");
    submit_profile(srgb, "switch to sRGB");
    pixels(srgb_pixels);
    unsigned color_change = pixel_difference(srgb_pixels, p3_pixels);
    printf("ICC PIXEL DIFFERENCE sRGB_to_P3=%u\n", color_change);
    require(color_change > 0, "Distinct genuine ICC profiles actually change rendered RGB pixels");
    clear_profile();
    pixels(repeated);
    require(pixel_difference(unmanaged, repeated) == 0, "Clearing ICC restores the original unmanaged output");
    submit_profile(p3, "restore profile after clearing");
    pixels(repeated);
    require(pixel_difference(p3_pixels, repeated) == 0, "Restoring P3 restores the exact transformed output");
    set_auto(false);
    submit_profile(srgb, "disabled again with another caller-owned buffer");
    pixels(repeated);
    require(pixel_difference(unmanaged, repeated) == 0, "Disabling ICC preserves unmanaged rendering");
    set_auto(true);
    submit_profile(p3, "active profile retained until renderer destruction");
    pixels(repeated);
    require(pixel_difference(p3_pixels, repeated) == 0, "Re-enabling ICC immediately restores the exact P3 transform");
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
    printf("PASS: ICC ownership and actual color-transform pixels: %u checks, %u real renders; no GUI or user media.\n", checks, frames);
  }
  return 0;
}
