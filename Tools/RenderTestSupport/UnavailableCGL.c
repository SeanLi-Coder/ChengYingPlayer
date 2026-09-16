// Boundary-only fixture: exercise the real soak harness's no-context branch.
#define GL_SILENCE_DEPRECATION
#include <OpenGL/OpenGL.h>
#include <stdio.h>

CGLError unavailable_test_pixel_format(const CGLPixelFormatAttribute *attributes,
                                      CGLPixelFormatObj *format, GLint *count) {
  (void)attributes;
  *format = NULL;
  *count = 0;
  fputs("BOUNDARY: CGL pixel format unavailable\n", stderr);
  return kCGLBadPixelFormat;
}
