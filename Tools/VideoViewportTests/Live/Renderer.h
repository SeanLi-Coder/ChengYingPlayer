#ifndef VIDEO_VIEWPORT_LIVE_RENDERER_H
#define VIDEO_VIEWPORT_LIVE_RENDERER_H

#include <stdbool.h>

typedef struct {
  double center_x;
  double center_y;
  double width;
  double height;
  double position;
  double speed;
  double zoom;
  double pan_x;
  double pan_y;
  double display_width;
  double display_height;
  double window_scale;
  int paused;
  bool window_unchanged;
  unsigned frames;
} ViewportLiveSnapshot;

bool viewport_live_open(const char *path, bool hardware);
bool viewport_live_graphics_unavailable(void);
bool viewport_live_get_double(const char *name, double *value);
bool viewport_live_set_double(const char *name, double value);
bool viewport_live_set_speed(double speed);
bool viewport_live_set_paused(bool paused);
bool viewport_live_seek(double position);
bool viewport_live_wait(double seconds);
bool viewport_live_snapshot(ViewportLiveSnapshot *snapshot);
void viewport_live_close(void);

#endif
