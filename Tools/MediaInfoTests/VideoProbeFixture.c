#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static void record_pid(const char *source) {
  char path[4096];
  if (snprintf(path, sizeof(path), "%s.pid", source) >= (int)sizeof(path)) exit(20);
  FILE *file = fopen(path, "w");
  if (!file) exit(21);
  fprintf(file, "%d", getpid());
  fclose(file);
}

int main(int argc, char **argv) {
  for (int index = 1; index < argc; index++) {
    if (strcmp(argv[index], "-show_pixel_formats") == 0) {
      puts("{\"pixel_formats\":[{\"name\":\"yuv420p\",\"components\":[{\"bit_depth\":8},{\"bit_depth\":8},{\"bit_depth\":8}]}]}");
      return 0;
    }
  }
  const char *source = argc > 1 ? argv[argc - 1] : "";
  record_pid(source);
  if (strstr(source, "slow")) {
    signal(SIGTERM, SIG_IGN);
    for (;;) usleep(10000);
  }
  if (strstr(source, "flood")) {
    char block[16384];
    memset(block, 'x', sizeof(block));
    int descriptor = strstr(source, "stderr") ? STDERR_FILENO : STDOUT_FILENO;
    for (;;) {
      if (write(descriptor, block, sizeof(block)) < 0 && errno != EINTR) return 0;
    }
  }
  if (strstr(source, "malformed")) {
    puts("not JSON");
    return 0;
  }
  if (strstr(source, "error")) {
    fputs("fixture diagnostic\n", stderr);
    return 17;
  }
  int local_only = 0;
  for (int index = 1; index + 1 < argc; index++) {
    if (strcmp(argv[index], "-protocol_whitelist") == 0 && strcmp(argv[index + 1], "file") == 0) local_only = 1;
  }
  if (!local_only) return 18;
  if (getenv("FFREPORT") || getenv("https_proxy") || getenv("DYLD_INSERT_LIBRARIES")) return 19;
  puts("{\"format\":{\"format_name\":\"fixture\",\"duration\":\"1.5\"},\"streams\":[{\"index\":0,\"codec_type\":\"video\",\"codec_name\":\"h264\",\"pix_fmt\":\"yuv420p\",\"width\":320,\"height\":180}]} ");
  return 0;
}
