#include <mpv/client.h>
#include <stdbool.h>
#include <stdint.h>

bool clip_renderer_open(mpv_handle *player);
bool clip_renderer_pump(void);
uint64_t clip_renderer_hash(void);
unsigned clip_renderer_frames(void);
void clip_renderer_close(void);
