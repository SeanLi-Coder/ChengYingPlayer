// Exercise the shipped decoder and OpenGL renderer without user media or settings.
#define GL_SILENCE_DEPRECATION
#include <OpenGL/OpenGL.h>
#include <OpenGL/CGLRenderers.h>
#include <OpenGL/gl3.h>
#include <dlfcn.h>
#include <errno.h>
#include <inttypes.h>
#include <mach/mach.h>
#include <math.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <mpv/client.h>
#include <mpv/render_gl.h>

enum { VIDEO_WIDTH = 3840, VIDEO_HEIGHT = 2160, MAX_SAMPLES = 16000 };
static const uint64_t MIB = 1024 * 1024;
static atomic_bool render_pending;
static atomic_bool controller_done;
static atomic_bool failed;
static atomic_bool verified_hardware;
static atomic_bool verified_software;
static atomic_uint loaded_count;
static atomic_uint seek_count;
static atomic_uint speed_count;
static atomic_uint switch_count;
static double rss_samples[MAX_SAMPLES];
static double footprint_samples[MAX_SAMPLES];
static size_t memory_count;
static bool graphics_unavailable;

typedef struct {
  mpv_handle *mpv;
  const char *paths[2];
  const char *mode;
  double duration;
  double started;
} Controller;

static double monotonic_time(void) {
  struct timespec now;
  if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) abort();
  return (double)now.tv_sec + (double)now.tv_nsec / 1e9;
}

static void fail(const char *message) {
  fprintf(stderr, "FAIL: %s\n", message);
  atomic_store(&failed, true);
}

static bool checked(int result, const char *operation) {
  if (result >= 0) return true;
  fprintf(stderr, "FAIL: %s: %s\n", operation, mpv_error_string(result));
  atomic_store(&failed, true);
  return false;
}

static void update_callback(void *context) {
  (void)context;
  atomic_store(&render_pending, true);
}

static void *get_proc_address(void *context, const char *name) {
  return dlsym(context, name);
}

static uint64_t framebuffer_hash(GLuint fbo) {
  uint64_t hash = UINT64_C(1469598103934665603);
  glBindFramebuffer(GL_READ_FRAMEBUFFER, fbo);
  glReadBuffer(GL_COLOR_ATTACHMENT0);
  for (int row = 1; row < 8; row++) {
    for (int column = 1; column < 8; column++) {
      unsigned char pixel[4] = {0};
      glReadPixels(column * VIDEO_WIDTH / 8, row * VIDEO_HEIGHT / 8,
                   1, 1, GL_RGBA, GL_UNSIGNED_BYTE, pixel);
      for (int byte = 0; byte < 3; byte++) {
        hash ^= pixel[byte];
        hash *= UINT64_C(1099511628211);
      }
    }
  }
  glBindFramebuffer(GL_READ_FRAMEBUFFER, 0);
  return hash;
}

static bool sample_memory(double elapsed, unsigned generation, unsigned frames) {
  task_vm_info_data_t info;
  mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
  kern_return_t result = task_info(mach_task_self(), TASK_VM_INFO,
                                  (task_info_t)&info, &count);
  if (result != KERN_SUCCESS) {
    fail("Unable to read task memory statistics");
    return false;
  }
  double rss = (double)info.resident_size / MIB;
  double footprint = (double)info.phys_footprint / MIB;
  if (memory_count >= MAX_SAMPLES) {
    fail("Memory sample budget exhausted");
    return false;
  }
  rss_samples[memory_count] = rss;
  footprint_samples[memory_count++] = footprint;
  printf("SAMPLE generation=%u elapsed=%.1f frames=%u rss_mib=%.1f footprint_mib=%.1f\n",
         generation, elapsed, frames, rss, footprint);
  fflush(stdout);
  // The isolated 4K fixture and three contexts should never consume gigabytes.
  // This is a broad runaway guard, not a claim that every driver's cache is equal.
  if (rss > 2048 || footprint > 2048) {
    fail("The isolated 4K renderer exceeded the 2 GiB runaway-memory guard");
    return false;
  }
  return true;
}

static void check_video_parameters(Controller *controller) {
  int64_t width = 0, height = 0;
  if (!checked(mpv_get_property(controller->mpv, "width", MPV_FORMAT_INT64, &width), "Read video width") ||
      !checked(mpv_get_property(controller->mpv, "height", MPV_FORMAT_INT64, &height), "Read video height")) return;
  if (width != VIDEO_WIDTH || height != VIDEO_HEIGHT) fail("The decoder did not retain the fixture's 4K resolution");
  char *codec = mpv_get_property_string(controller->mpv, "video-codec");
  char *hardware = mpv_get_property_string(controller->mpv, "hwdec-current");
  printf("DECODER codec=%s hwdec=%s size=%" PRId64 "x%" PRId64 "\n",
         codec ? codec : "unavailable", hardware ? hardware : "unavailable", width, height);
  fflush(stdout);
  if (strcmp(controller->mode, "hardware") == 0) {
    if (!hardware || strcmp(hardware, "videotoolbox") != 0) {
      fail("VideoToolbox direct hardware decoding was not active; software fallback is not a hardware pass");
    } else {
      atomic_store(&verified_hardware, true);
    }
  } else {
    if (!hardware || strcmp(hardware, "no") != 0) fail("The explicitly requested software-decoding mode was not active");
    else atomic_store(&verified_software, true);
  }
  mpv_free(codec);
  mpv_free(hardware);
}

static void *control_playback(void *context) {
  Controller *controller = context;
  mpv_handle *mpv = controller->mpv;
  const char *load[] = {"loadfile", controller->paths[0], "replace", NULL};
  if (!checked(mpv_command(mpv, load), "Load first 4K fixture")) goto finished;
  double last_loaded = monotonic_time();
  double last_frame = last_loaded;
  double next_seek = last_loaded + 11;
  double next_speed = last_loaded + 17;
  double switch_interval = fmin(43, controller->duration / 2);
  double next_switch = last_loaded + switch_interval;
  unsigned speed_index = 0, active_path = 0;
  bool loaded = false, verified = false, waiting_for_switch = false;
  double last_position = -1;
  double next_position = last_loaded + 1;
  while (!atomic_load(&failed) && monotonic_time() - controller->started < controller->duration) {
    mpv_event *event = mpv_wait_event(mpv, 0.01);
    if (event->event_id == MPV_EVENT_SHUTDOWN) {
      fail("libmpv shut down unexpectedly");
      break;
    }
    if (event->event_id == MPV_EVENT_FILE_LOADED) {
      loaded = true;
      verified = false;
      last_loaded = monotonic_time();
      last_frame = last_loaded;
      atomic_fetch_add(&loaded_count, 1);
      if (waiting_for_switch) {
        atomic_fetch_add(&switch_count, 1);
        waiting_for_switch = false;
      }
    } else if (event->event_id == MPV_EVENT_END_FILE) {
      mpv_event_end_file *end = event->data;
      if (end->reason == MPV_END_FILE_REASON_ERROR) {
        checked(end->error, "Decode fixture");
        break;
      }
    } else if (event->event_id == MPV_EVENT_LOG_MESSAGE) {
      mpv_event_log_message *log = event->data;
      fprintf(stderr, "MPV %s: %s", log->prefix, log->text);
    }
    double now = monotonic_time();
    if (!loaded && now - last_loaded > 15) {
      fail("No file-loaded event within 15 seconds");
      break;
    }
    if (!loaded) continue;
    if (!verified && now - last_loaded > 0.5) {
      check_video_parameters(controller);
      verified = true;
    }
    if (now >= next_position) {
      double position = -1;
      if (!checked(mpv_get_property(mpv, "time-pos", MPV_FORMAT_DOUBLE, &position), "Read playback position")) break;
      if (isfinite(position) && fabs(position - last_position) > 0.001) last_frame = now;
      last_position = position;
      next_position = now + 1;
      if (now - last_frame > 15) {
        fail("Playback stopped making progress for 15 seconds");
        break;
      }
    }
    if (now >= next_seek) {
      const char *seek[] = {"seek", atomic_load(&seek_count) % 2 ? "1.25" : "3.5", "absolute+exact", NULL};
      if (!checked(mpv_command(mpv, seek), "Seek inside 4K fixture")) break;
      atomic_fetch_add(&seek_count, 1);
      next_seek = now + 11;
    }
    if (now >= next_speed) {
      const char *speeds[] = {"1.2", "0.8", "2.0", "1.0"};
      if (!checked(mpv_set_property_string(mpv, "speed", speeds[speed_index++ % 4]), "Change playback speed")) break;
      atomic_fetch_add(&speed_count, 1);
      next_speed = now + 17;
    }
    if (now >= next_switch && now + 1 < controller->started + controller->duration) {
      active_path = 1 - active_path;
      const char *replace[] = {"loadfile", controller->paths[active_path], "replace", NULL};
      if (!checked(mpv_command(mpv, replace), "Switch codec without recreating renderer")) break;
      waiting_for_switch = true;
      loaded = false;
      last_loaded = now;
      next_switch = now + switch_interval;
    }
  }
finished:;
  // The render thread keeps servicing callbacks while the core stops.
  const char *stop[] = {"stop", NULL};
  checked(mpv_command(mpv, stop), "Stop the decoder before freeing render resources");
  atomic_store(&controller_done, true);
  return NULL;
}

static bool run_generation(const char *first, const char *second, const char *mode,
                           double duration, unsigned generation) {
  CGLPixelFormatObj pixel_format = NULL;
  CGLContextObj gl_context = NULL;
  mpv_handle *mpv = NULL;
  mpv_render_context *renderer = NULL;
  void *gl_library = NULL;
  GLuint texture = 0, fbo = 0;
  unsigned frames = 0, changed_hashes = 0;
  uint64_t previous_hash = 0;
  pthread_t controller_thread;
  atomic_store(&render_pending, false);
  atomic_store(&controller_done, false);

  CGLPixelFormatAttribute accelerated_attributes[] = {
    kCGLPFAOpenGLProfile, (CGLPixelFormatAttribute)kCGLOGLPVersion_3_2_Core,
    kCGLPFAAccelerated, kCGLPFAAllowOfflineRenderers, (CGLPixelFormatAttribute)0
  };
  CGLPixelFormatAttribute software_attributes[] = {
    kCGLPFAOpenGLProfile, (CGLPixelFormatAttribute)kCGLOGLPVersion_3_2_Core,
    kCGLPFARendererID, (CGLPixelFormatAttribute)kCGLRendererGenericFloatID,
    (CGLPixelFormatAttribute)0
  };
  const bool software_mode = strcmp(mode, "software") == 0;
  bool context_ready = false;
  GLint pixel_count = 0;
  for (unsigned attempt = 0; attempt < (software_mode ? 2u : 1u); attempt++) {
    CGLPixelFormatAttribute *attributes = attempt ? software_attributes : accelerated_attributes;
    if (CGLChoosePixelFormat(attributes, &pixel_format, &pixel_count) == kCGLNoError && pixel_format &&
        CGLCreateContext(pixel_format, NULL, &gl_context) == kCGLNoError && gl_context &&
        CGLSetCurrentContext(gl_context) == kCGLNoError) {
      context_ready = true;
      break;
    }
    if (gl_context) { CGLSetCurrentContext(NULL); CGLReleaseContext(gl_context); gl_context = NULL; }
    if (pixel_format) { CGLReleasePixelFormat(pixel_format); pixel_format = NULL; }
  }
  if (!context_ready) {
    if (software_mode && generation == 1) {
      graphics_unavailable = true;
      fprintf(stderr, "UNAVAILABLE: Neither accelerated nor Generic Float CGL 3.2 is available; no GL test ran\n");
    } else {
      fail("A required CGL 3.2 context is unavailable; no null-VO substitute was used");
    }
    goto cleanup;
  }
  printf("GPU generation=%u renderer=%s version=%s mode=%s\n", generation,
         glGetString(GL_RENDERER), glGetString(GL_VERSION), mode);
  gl_library = dlopen("/System/Library/Frameworks/OpenGL.framework/OpenGL", RTLD_NOW | RTLD_LOCAL);
  if (!gl_library) { fail("Unable to load the system OpenGL entry points"); goto cleanup; }
  mpv = mpv_create();
  if (!mpv) { fail("Unable to create the shipped libmpv core"); goto cleanup; }
  const char *options[][2] = {
    {"config", "no"}, {"terminal", "no"},
    {"input-default-bindings", "no"}, {"input-terminal", "no"}, {"idle", "yes"},
    {"vo", "libmpv"}, {"ao", "null"}, {"loop-file", "inf"}, {"keep-open", "yes"},
    {"gpu-hwdec-interop", "auto"}, {"hwdec", strcmp(mode, "hardware") == 0 ? "auto" : "no"},
    {"cache", "no"}, {"video-timing-offset", "0"}, {"osd-level", "0"},
    {"audio-display", "no"}, {"screenshot-directory", "/dev/null"}
  };
  for (size_t index = 0; index < sizeof(options) / sizeof(options[0]); index++) {
    if (!checked(mpv_set_option_string(mpv, options[index][0], options[index][1]), options[index][0])) goto cleanup;
  }
  if (!checked(mpv_initialize(mpv), "Initialize libmpv")) goto cleanup;
  char *mpv_version = mpv_get_property_string(mpv, "mpv-version");
  char *ffmpeg_version = mpv_get_property_string(mpv, "ffmpeg-version");
  printf("VERSIONS mpv=%s ffmpeg=%s\n", mpv_version ? mpv_version : "unknown", ffmpeg_version ? ffmpeg_version : "unknown");
  mpv_free(mpv_version);
  mpv_free(ffmpeg_version);
  checked(mpv_request_log_messages(mpv, "error"), "Subscribe to decoder errors");
  mpv_opengl_init_params initialization = {get_proc_address, gl_library};
  int advanced = 1;
  mpv_render_param parameters[] = {
    {MPV_RENDER_PARAM_API_TYPE, MPV_RENDER_API_TYPE_OPENGL},
    {MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, &initialization},
    {MPV_RENDER_PARAM_ADVANCED_CONTROL, &advanced}, {MPV_RENDER_PARAM_INVALID, NULL}
  };
  if (!checked(mpv_render_context_create(&renderer, mpv, parameters), "Create the actual OpenGL render context")) goto cleanup;
  mpv_render_context_set_update_callback(renderer, update_callback, NULL);
  glGenTextures(1, &texture);
  glBindTexture(GL_TEXTURE_2D, texture);
  glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, VIDEO_WIDTH, VIDEO_HEIGHT, 0, GL_RGBA, GL_UNSIGNED_BYTE, NULL);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
  glBindTexture(GL_TEXTURE_2D, 0);
  glGenFramebuffers(1, &fbo);
  glBindFramebuffer(GL_FRAMEBUFFER, fbo);
  glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, texture, 0);
  if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) { fail("The 4K framebuffer is incomplete"); goto cleanup; }
  glBindFramebuffer(GL_FRAMEBUFFER, 0);
  Controller controller = {mpv, {first, second}, mode, duration, monotonic_time()};
  if (pthread_create(&controller_thread, NULL, control_playback, &controller) != 0) { fail("Unable to start the independent playback controller"); goto cleanup; }
  double next_sample = controller.started + 1;
  while (!atomic_load(&controller_done)) {
    if (atomic_exchange(&render_pending, false)) {
      uint64_t flags = mpv_render_context_update(renderer);
      if (flags & MPV_RENDER_UPDATE_FRAME) {
        mpv_opengl_fbo target = {(int)fbo, VIDEO_WIDTH, VIDEO_HEIGHT, GL_RGBA8};
        int flip = 1, depth = 8;
        mpv_render_param draw[] = {
          {MPV_RENDER_PARAM_OPENGL_FBO, &target}, {MPV_RENDER_PARAM_FLIP_Y, &flip},
          {MPV_RENDER_PARAM_DEPTH, &depth}, {MPV_RENDER_PARAM_INVALID, NULL}
        };
        checked(mpv_render_context_render(renderer, draw), "Render an actual 4K frame");
        glFlush();
        mpv_render_context_report_swap(renderer);
        frames++;
      }
    }
    double now = monotonic_time();
    if (now >= next_sample) {
      uint64_t hash = framebuffer_hash(fbo);
      if (previous_hash && previous_hash != hash) changed_hashes++;
      previous_hash = hash;
      if (glGetError() != GL_NO_ERROR) fail("OpenGL reported an error rendering or sampling the 4K frame");
      sample_memory(now - controller.started, generation, frames);
      next_sample = now + 1;
    }
    if (now - controller.started > duration + 20) {
      // A stuck core may block pthread_join. The outer runner has another deadline.
      fprintf(stderr, "FAIL: Renderer/controller shutdown deadline exceeded\n");
      _Exit(1);
    }
    struct timespec delay = {0, 1000000};
    nanosleep(&delay, NULL);
  }
  pthread_join(controller_thread, NULL);
  if (frames < duration * 3 || changed_hashes < 3) fail("Insufficient rendered frames or changing GPU output to verify playback");
  printf("GENERATION generation=%u frames=%u changed_hashes=%u duration=%.1f\n", generation, frames, changed_hashes, duration);
cleanup:
  if (renderer) {
    mpv_render_context_set_update_callback(renderer, NULL, NULL);
    mpv_render_context_free(renderer);
  }
  if (mpv) mpv_terminate_destroy(mpv);
  if (fbo) glDeleteFramebuffers(1, &fbo);
  if (texture) glDeleteTextures(1, &texture);
  if (gl_context) { glFinish(); CGLSetCurrentContext(NULL); CGLReleaseContext(gl_context); }
  if (pixel_format) CGLReleasePixelFormat(pixel_format);
  if (gl_library) dlclose(gl_library);
  return !graphics_unavailable && !atomic_load(&failed);
}

static int compare_double(const void *left, const void *right) {
  double first = *(const double *)left, second = *(const double *)right;
  return (first > second) - (first < second);
}

static double median(const double *samples, size_t start, size_t count) {
  double *copy = malloc(count * sizeof(*copy));
  if (!copy) abort();
  memcpy(copy, samples + start, count * sizeof(*copy));
  qsort(copy, count, sizeof(*copy), compare_double);
  double result = copy[count / 2];
  free(copy);
  return result;
}

int main(int argc, char **argv) {
  if (argc != 6) {
    fprintf(stderr, "Usage: PlaybackSoakTests H264 HEVC SECONDS hardware|software AVCODEC_LIBRARY\n");
    return 2;
  }
  char *end = NULL;
  errno = 0;
  double duration = strtod(argv[3], &end);
  if (errno || !end || *end || !isfinite(duration) || duration < 60 || duration > 14400 ||
      (strcmp(argv[4], "hardware") != 0 && strcmp(argv[4], "software") != 0)) {
    fprintf(stderr, "FAIL: Expected 60..14400 seconds and an explicit hardware or software mode\n");
    return 2;
  }
  void *codec = dlopen(argv[5], RTLD_NOW | RTLD_LOCAL);
  const char *(*configuration)(void) = codec ? dlsym(codec, "avcodec_configuration") : NULL;
  const void *(*find_decoder)(const char *) = codec ? dlsym(codec, "avcodec_find_decoder_by_name") : NULL;
  const char *configuration_text = configuration ? configuration() : NULL;
  if (!configuration_text || !strstr(configuration_text, "--enable-libdav1d") ||
      !find_decoder || !find_decoder("libdav1d")) {
    fprintf(stderr, "FAIL: The loaded FFmpeg library does not expose the pinned dav1d decoder\n");
    if (codec) dlclose(codec);
    return 1;
  }
  printf("DECODER libdav1d=available architecture=%s\n",
#if defined(__arm64__)
         "arm64"
#else
         "x86_64"
#endif
  );
  dlclose(codec);
  for (unsigned generation = 1; generation <= 3; generation++) {
    const char *first = generation % 2 ? argv[1] : argv[2];
    const char *second = generation % 2 ? argv[2] : argv[1];
    if (!run_generation(first, second, argv[4], duration / 3, generation)) return graphics_unavailable ? 77 : 1;
  }
  if (memory_count < 15) { fail("Insufficient memory samples"); return 1; }
  size_t window = memory_count / 6;
  // Compare warmed-up windows, not the initially unloaded process against a decoder.
  double rss_start = median(rss_samples, window, window);
  double rss_end = median(rss_samples, memory_count - window, window);
  double footprint_start = median(footprint_samples, window, window);
  double footprint_end = median(footprint_samples, memory_count - window, window);
  printf("MEMORY samples=%zu rss_start_mib=%.1f rss_end_mib=%.1f rss_growth_mib=%.1f footprint_growth_mib=%.1f\n",
         memory_count, rss_start, rss_end, rss_end - rss_start, footprint_end - footprint_start);
  if (rss_end - rss_start > 256 || footprint_end - footprint_start > 256) fail("Warm renderer memory grew by more than the 256 MiB regression budget");
  if (atomic_load(&loaded_count) < 6 || atomic_load(&switch_count) < 3 ||
      atomic_load(&seek_count) < 3 || atomic_load(&speed_count) < 3) fail("Expected playback transitions were not exercised");
  if (atomic_load(&failed)) return 1;
  printf("PASS: Actual 4K OpenGL render soak seconds=%.0f mode=%s hardware_verified=%d software_verified=%d loads=%u switches=%u seeks=%u speed_changes=%u\n",
         duration, argv[4], atomic_load(&verified_hardware), atomic_load(&verified_software),
         atomic_load(&loaded_count), atomic_load(&switch_count), atomic_load(&seek_count), atomic_load(&speed_count));
  return 0;
}
