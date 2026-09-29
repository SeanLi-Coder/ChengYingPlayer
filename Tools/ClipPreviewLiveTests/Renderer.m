// Use the real libmpv software renderer, not a synthesized playback image.
#import <AppKit/AppKit.h>
#include <mpv/render.h>
#include <stdatomic.h>
#include "Renderer.h"

enum { WIDTH = 320, HEIGHT = 180 };
static mpv_render_context *renderer;
static atomic_bool pending;
static unsigned char *pixels;
static unsigned frames;
static uint64_t pixel_hash;
static NSWindow *window;
static NSImageView *view;

static void update(void *unused) { atomic_store(&pending, true); }

bool clip_renderer_open(mpv_handle *player) {
  int advanced = 1;
  mpv_render_param params[] = {
    {MPV_RENDER_PARAM_API_TYPE, MPV_RENDER_API_TYPE_SW},
    {MPV_RENDER_PARAM_ADVANCED_CONTROL, &advanced},
    {MPV_RENDER_PARAM_INVALID, NULL}
  };
  if (mpv_render_context_create(&renderer, player, params) < 0) return false;
  if (posix_memalign((void **)&pixels, 64, WIDTH * HEIGHT * 4) != 0) return false;
  mpv_render_context_set_update_callback(renderer, update, NULL);
  window = [[NSWindow alloc] initWithContentRect:NSMakeRect(80, 240, WIDTH * 2, HEIGHT * 2)
    styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
    backing:NSBackingStoreBuffered defer:NO];
  window.releasedWhenClosed = NO;
  window.title = @"Clip Preview Live Test - Real Decoded Frames";
  view = [[NSImageView alloc] initWithFrame:window.contentView.bounds];
  view.imageScaling = NSImageScaleProportionallyUpOrDown;
  window.contentView = view;
  [window orderFront:nil];
  return true;
}

bool clip_renderer_pump(void) {
  if (!renderer || !atomic_exchange(&pending, false)) return true;
  if (!(mpv_render_context_update(renderer) & MPV_RENDER_UPDATE_FRAME)) return true;
  int dimensions[] = {WIDTH, HEIGHT};
  size_t stride = WIDTH * 4;
  mpv_render_param params[] = {
    {MPV_RENDER_PARAM_SW_SIZE, dimensions}, {MPV_RENDER_PARAM_SW_FORMAT, "rgb0"},
    {MPV_RENDER_PARAM_SW_STRIDE, &stride}, {MPV_RENDER_PARAM_SW_POINTER, pixels},
    {MPV_RENDER_PARAM_INVALID, NULL}
  };
  if (mpv_render_context_render(renderer, params) < 0) return false;
  pixel_hash = UINT64_C(1469598103934665603);
  for (size_t index = 0; index < WIDTH * HEIGHT * 4; index += 4) {
    for (size_t component = 0; component < 3; component++) {
      pixel_hash = (pixel_hash ^ pixels[index + component]) * UINT64_C(1099511628211);
    }
  }
  NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc]
    initWithBitmapDataPlanes:NULL pixelsWide:WIDTH pixelsHigh:HEIGHT
    bitsPerSample:8 samplesPerPixel:3 hasAlpha:NO isPlanar:NO
    colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:WIDTH * 3 bitsPerPixel:24];
  if (!bitmap) return false;
  for (size_t index = 0; index < WIDTH * HEIGHT; index++) {
    memcpy(bitmap.bitmapData + index * 3, pixels + index * 4, 3);
  }
  NSImage *image = [[NSImage alloc] initWithSize:NSMakeSize(WIDTH, HEIGHT)];
  [image addRepresentation:bitmap];
  view.image = image;
  mpv_render_context_report_swap(renderer);
  frames++;
  return true;
}

uint64_t clip_renderer_hash(void) { return pixel_hash; }
unsigned clip_renderer_frames(void) { return frames; }

void clip_renderer_close(void) {
  if (renderer) {
    mpv_render_context_set_update_callback(renderer, NULL, NULL);
    mpv_render_context_free(renderer);
    renderer = NULL;
  }
  free(pixels);
  pixels = NULL;
  [window close];
  view = nil;
  window = nil;
}
