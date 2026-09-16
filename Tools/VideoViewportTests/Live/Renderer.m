// Render generated media through the shipped libmpv in a real AppKit window.
#define GL_SILENCE_DEPRECATION
#import <AppKit/AppKit.h>
#include <OpenGL/CGLRenderers.h>
#include <OpenGL/gl3.h>
#include <dlfcn.h>
#include <math.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <mpv/client.h>
#include <mpv/render_gl.h>
#include "Renderer.h"

enum { WIDTH = 640, HEIGHT = 360 };
static NSWindow *window;
static NSOpenGLView *view;
static NSRect original_frame;
static mpv_handle *player;
static mpv_render_context *renderer;
static void *gl_library;
static GLuint texture, framebuffer;
static atomic_bool render_pending;
static bool failed, loaded;
static bool graphics_unavailable;
static unsigned frame_count;
static uint64_t next_request = 1, awaited_request;
static bool received_reply;
static double reply_value;
static char reply_string[128];

static double now(void) {
  struct timespec value;
  if (clock_gettime(CLOCK_MONOTONIC, &value) != 0) abort();
  return value.tv_sec + value.tv_nsec / 1e9;
}

static bool check(int result, const char *operation) {
  if (result >= 0) return true;
  fprintf(stderr, "FAIL: %s: %s\n", operation, mpv_error_string(result));
  failed = true;
  return false;
}

static bool require(bool condition, const char *message) {
  if (!condition) {
    fprintf(stderr, "FAIL: %s\n", message);
    failed = true;
  }
  return condition;
}

static void update(void *context) {
  (void)context;
  atomic_store(&render_pending, true);
}

static void *get_proc(void *context, const char *name) {
  return dlsym(context, name);
}

static void render(void) {
  if (!renderer || !atomic_exchange(&render_pending, false)) return;
  [view.openGLContext makeCurrentContext];
  if (!(mpv_render_context_update(renderer) & MPV_RENDER_UPDATE_FRAME)) return;
  mpv_opengl_fbo target = {(int)framebuffer, WIDTH, HEIGHT, GL_RGBA8};
  int flip = 1, depth = 8;
  mpv_render_param parameters[] = {
    {MPV_RENDER_PARAM_OPENGL_FBO, &target}, {MPV_RENDER_PARAM_FLIP_Y, &flip},
    {MPV_RENDER_PARAM_DEPTH, &depth}, {MPV_RENDER_PARAM_INVALID, NULL}
  };
  if (!check(mpv_render_context_render(renderer, parameters), "Render the viewport")) return;
  glBindFramebuffer(GL_READ_FRAMEBUFFER, framebuffer);
  glBindFramebuffer(GL_DRAW_FRAMEBUFFER, 0);
  NSRect backing = [view convertRectToBacking:view.bounds];
  glBlitFramebuffer(0, 0, WIDTH, HEIGHT, 0, 0,
                    (GLint)backing.size.width, (GLint)backing.size.height,
                    GL_COLOR_BUFFER_BIT, GL_NEAREST);
  glBindFramebuffer(GL_FRAMEBUFFER, 0);
  [view.openGLContext flushBuffer];
  mpv_render_context_report_swap(renderer);
  frame_count++;
}

static void pump(void) {
  @autoreleasepool {
    NSEvent *event;
    while ((event = [NSApp nextEventMatchingMask:NSEventMaskAny
                                      untilDate:[NSDate date]
                                         inMode:NSDefaultRunLoopMode dequeue:YES])) {
      [NSApp sendEvent:event];
    }
    [NSApp updateWindows];
    render();
    if (player) {
      for (;;) {
        mpv_event *event = mpv_wait_event(player, 0);
        if (event->event_id == MPV_EVENT_NONE) break;
        if (event->event_id == MPV_EVENT_FILE_LOADED) loaded = true;
        if (event->event_id == MPV_EVENT_SHUTDOWN) require(false, "Unexpected player shutdown");
        if (event->event_id == MPV_EVENT_END_FILE) {
          mpv_event_end_file *end = event->data;
          if (end->reason == MPV_END_FILE_REASON_ERROR) check(end->error, "Decode generated media");
        }
        if (event->reply_userdata && event->reply_userdata == awaited_request) {
          check(event->error, "Complete an asynchronous player request");
          if (event->event_id == MPV_EVENT_GET_PROPERTY_REPLY && event->error >= 0) {
            mpv_event_property *property = event->data;
            if (property->format == MPV_FORMAT_DOUBLE && property->data) {
              reply_value = *(double *)property->data;
            } else if (property->format == MPV_FORMAT_FLAG && property->data) {
              reply_value = *(int *)property->data;
            } else if (property->format == MPV_FORMAT_STRING && property->data) {
              const char *value = *(char **)property->data;
              snprintf(reply_string, sizeof(reply_string), "%s", value ? value : "");
            } else {
              require(false, "Unexpected player property result format");
            }
          }
          received_reply = true;
        }
      }
    }
    [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.001]];
  }
}

static bool await_reply(void) {
  double deadline = now() + 8;
  while (!failed && !received_reply && now() < deadline) pump();
  return require(received_reply, "The player request exceeded its deadline") && !failed;
}

static uint64_t request(void) {
  awaited_request = next_request++;
  received_reply = false;
  return awaited_request;
}

static bool set_double(const char *name, double value) {
  return check(mpv_set_property_async(player, request(), name, MPV_FORMAT_DOUBLE, &value), name) && await_reply();
}

static bool read_value(const char *name, mpv_format format, double *value) {
  if (!check(mpv_get_property_async(player, request(), name, format), name) || !await_reply()) return false;
  *value = reply_value;
  return true;
}

bool viewport_live_wait(double seconds) {
  double deadline = now() + seconds;
  while (!failed && now() < deadline) pump();
  return !failed;
}

bool viewport_live_open(const char *path, bool hardware) {
  graphics_unavailable = false;
  [NSApplication sharedApplication];
  [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
  [NSApp finishLaunching];
  NSOpenGLPixelFormatAttribute accelerated_attributes[] = {
    NSOpenGLPFAOpenGLProfile, NSOpenGLProfileVersion3_2Core,
    NSOpenGLPFADoubleBuffer, NSOpenGLPFAAccelerated,
    NSOpenGLPFAAllowOfflineRenderers, NSOpenGLPFAColorSize, 24, 0
  };
  NSOpenGLPixelFormatAttribute software_attributes[] = {
    NSOpenGLPFAOpenGLProfile, NSOpenGLProfileVersion3_2Core,
    NSOpenGLPFADoubleBuffer, NSOpenGLPFARendererID, kCGLRendererGenericFloatID,
    NSOpenGLPFAColorSize, 24, 0
  };
  NSOpenGLPixelFormat *format = nil;
  NSOpenGLContext *context = nil;
  for (unsigned attempt = 0; attempt < (hardware ? 1u : 2u); attempt++) {
    NSOpenGLPixelFormatAttribute *attributes = attempt ? software_attributes : accelerated_attributes;
    format = [[NSOpenGLPixelFormat alloc] initWithAttributes:attributes];
    if (format) context = [[NSOpenGLContext alloc] initWithFormat:format shareContext:nil];
    if (context) break;
  }
  if (!context) {
    if (!hardware) {
      graphics_unavailable = true;
      fprintf(stderr, "UNAVAILABLE: Neither accelerated nor Generic Float AppKit CGL 3.2 is available; no GL test ran\n");
      return false;
    }
    return require(false, "A real accelerated OpenGL context is required in hardware mode");
  }
  window = [[NSWindow alloc] initWithContentRect:NSMakeRect(120, 120, WIDTH, HEIGHT)
                                       styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                                         backing:NSBackingStoreBuffered defer:NO];
  window.releasedWhenClosed = NO;
  window.title = @"Generated Video Viewport Test";
  view = [[NSOpenGLView alloc] initWithFrame:NSMakeRect(0, 0, WIDTH, HEIGHT) pixelFormat:format];
  view.openGLContext = context;
  window.contentView = view;
  [window orderFront:nil];
  [view.openGLContext makeCurrentContext];
  [view.openGLContext update];
  original_frame = window.frame;
  if (!require(view.openGLContext != nil, "A real AppKit OpenGL context is required")) return false;
  printf("GPU: %s\n", glGetString(GL_RENDERER));
  gl_library = dlopen("/System/Library/Frameworks/OpenGL.framework/OpenGL", RTLD_NOW | RTLD_LOCAL);
  if (!require(gl_library != NULL, "System OpenGL entry points are required")) return false;
  player = mpv_create();
  if (!require(player != NULL, "The shipped libmpv must initialize")) return false;
  const char *options[][2] = {
    {"config", "no"}, {"terminal", "no"},
    {"input-default-bindings", "no"}, {"input-terminal", "no"}, {"idle", "yes"},
    {"vo", "libmpv"}, {"ao", "null"}, {"loop-file", "inf"}, {"keep-open", "yes"},
    {"gpu-hwdec-interop", "auto"}, {"hwdec", hardware ? "auto" : "no"},
    {"pause", "yes"}, {"cache", "no"}, {"video-timing-offset", "0"}, {"osd-level", "0"},
    {"audio-display", "no"}, {"keepaspect", "yes"}, {"scale", "bilinear"}, {"dscale", "bilinear"},
    {"correct-downscaling", "no"}, {"deband", "no"}, {"dither-depth", "no"}
  };
  for (unsigned index = 0; index < sizeof(options) / sizeof(options[0]); index++) {
    if (!check(mpv_set_option_string(player, options[index][0], options[index][1]), options[index][0])) return false;
  }
  if (!check(mpv_initialize(player), "Initialize the real player")) return false;
  mpv_opengl_init_params initialization = {get_proc, gl_library};
  int advanced = 1;
  mpv_render_param parameters[] = {
    {MPV_RENDER_PARAM_API_TYPE, MPV_RENDER_API_TYPE_OPENGL},
    {MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, &initialization},
    {MPV_RENDER_PARAM_ADVANCED_CONTROL, &advanced}, {MPV_RENDER_PARAM_INVALID, NULL}
  };
  if (!check(mpv_render_context_create(&renderer, player, parameters), "Create the OpenGL renderer")) return false;
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
  if (!require(glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE,
               "The real viewport framebuffer is complete")) return false;
  glBindFramebuffer(GL_FRAMEBUFFER, 0);
  const char *load[] = {"loadfile", path, "replace", NULL};
  if (!check(mpv_command_async(player, request(), load), "Load generated 4K media") || !await_reply()) return false;
  double deadline = now() + 15;
  while (!failed && (!loaded || frame_count < 1) && now() < deadline) pump();
  if (!require(loaded && frame_count > 0, "The generated video must load and render")) return false;
  if (!viewport_live_wait(0.2)) return false;
  double width = 0, height = 0;
  if (!read_value("width", MPV_FORMAT_DOUBLE, &width) ||
      !read_value("height", MPV_FORMAT_DOUBLE, &height) ||
      !require(width == 3840 && height == 2160, "The real decoder retains the 4K source dimensions")) return false;
  if (!check(mpv_get_property_async(player, request(), "hwdec-current", MPV_FORMAT_STRING), "Read the decoder mode") ||
      !await_reply()) return false;
  printf("DECODER: %s; SOURCE: %.0fx%.0f\n", reply_string, width, height);
  bool expected = strcmp(reply_string, hardware ? "videotoolbox" : "no") == 0;
  return require(expected, "The requested decoder mode must be active; no silent hardware fallback is allowed");
}

bool viewport_live_graphics_unavailable(void) {
  return graphics_unavailable;
}

bool viewport_live_get_double(const char *name, double *value) {
  return read_value(name, MPV_FORMAT_DOUBLE, value);
}

bool viewport_live_set_double(const char *name, double value) {
  return set_double(name, value);
}

bool viewport_live_set_speed(double speed) {
  return set_double("speed", speed);
}

bool viewport_live_set_paused(bool paused) {
  int value = paused;
  return check(mpv_set_property_async(player, request(), "pause", MPV_FORMAT_FLAG, &value), "Set pause") &&
         await_reply() && viewport_live_wait(0.05);
}

bool viewport_live_seek(double position) {
  char value[64];
  snprintf(value, sizeof(value), "%.6f", position);
  const char *seek[] = {"seek", value, "absolute+exact", NULL};
  return check(mpv_command_async(player, request(), seek), "Seek generated media") &&
         await_reply() && viewport_live_wait(0.20);
}

bool viewport_live_snapshot(ViewportLiveSnapshot *snapshot) {
  if (!snapshot || !player || failed) return false;
  memset(snapshot, 0, sizeof(*snapshot));
  double paused = 0;
  if (!read_value("time-pos", MPV_FORMAT_DOUBLE, &snapshot->position) ||
      !read_value("speed", MPV_FORMAT_DOUBLE, &snapshot->speed) ||
      !read_value("video-zoom", MPV_FORMAT_DOUBLE, &snapshot->zoom) ||
      !read_value("video-pan-x", MPV_FORMAT_DOUBLE, &snapshot->pan_x) ||
      !read_value("video-pan-y", MPV_FORMAT_DOUBLE, &snapshot->pan_y) ||
      !read_value("dwidth", MPV_FORMAT_DOUBLE, &snapshot->display_width) ||
      !read_value("dheight", MPV_FORMAT_DOUBLE, &snapshot->display_height) ||
      !read_value("window-scale", MPV_FORMAT_DOUBLE, &snapshot->window_scale) ||
      !read_value("pause", MPV_FORMAT_FLAG, &paused)) return false;
  snapshot->paused = (int)paused;
  snapshot->window_unchanged = NSEqualRects(window.frame, original_frame);
  snapshot->frames = frame_count;
  unsigned char *pixels = malloc(WIDTH * HEIGHT * 4);
  if (!require(pixels != NULL, "Pixel sample allocation succeeds")) return false;
  [view.openGLContext makeCurrentContext];
  glBindFramebuffer(GL_READ_FRAMEBUFFER, framebuffer);
  glReadBuffer(GL_COLOR_ATTACHMENT0);
  glReadPixels(0, 0, WIDTH, HEIGHT, GL_RGBA, GL_UNSIGNED_BYTE, pixels);
  glBindFramebuffer(GL_READ_FRAMEBUFFER, 0);
  int min_x = WIDTH, min_y = HEIGHT, max_x = -1, max_y = -1;
  for (int row = 0; row < HEIGHT; row++) {
    for (int column = 0; column < WIDTH; column++) {
      const unsigned char *pixel = &pixels[(row * WIDTH + column) * 4];
      if (pixel[0] > 170 && pixel[1] < 80 && pixel[2] < 80) {
        int top_y = HEIGHT - row - 1;
        if (column < min_x) min_x = column;
        if (column > max_x) max_x = column;
        if (top_y < min_y) min_y = top_y;
        if (top_y > max_y) max_y = top_y;
      }
    }
  }
  free(pixels);
  if (!require(max_x >= min_x && max_y >= min_y, "The rendered video contains its red reference marker")) return false;
  snapshot->center_x = (min_x + max_x) / 2.0;
  snapshot->center_y = (min_y + max_y) / 2.0;
  snapshot->width = max_x - min_x + 1;
  snapshot->height = max_y - min_y + 1;
  return require(glGetError() == GL_NO_ERROR, "Viewport rendering and pixel reads report no OpenGL error");
}

void viewport_live_close(void) {
  if (player && renderer && !failed) {
    const char *stop[] = {"stop", NULL};
    if (check(mpv_command_async(player, request(), stop), "Stop generated media")) await_reply();
    viewport_live_wait(0.05);
  }
  [view.openGLContext makeCurrentContext];
  if (renderer) {
    mpv_render_context_set_update_callback(renderer, NULL, NULL);
    mpv_render_context_free(renderer);
    renderer = NULL;
  }
  if (player) { mpv_terminate_destroy(player); player = NULL; }
  if (framebuffer) glDeleteFramebuffers(1, &framebuffer);
  if (texture) glDeleteTextures(1, &texture);
  glFinish();
  [NSOpenGLContext clearCurrentContext];
  [window close];
  view = nil;
  window = nil;
  if (gl_library) { dlclose(gl_library); gl_library = NULL; }
}
