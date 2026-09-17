#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

int main(int argc, char **argv) {
  if (argc < 2) return 10;
  const char *source = argv[argc - 1];
  struct stat before;
  if (stat(source, &before) != 0) return 11;
  if (strstr(source, "replaced-source")) {
    char replacement[4096];
    if (snprintf(replacement, sizeof(replacement), "%s.replacement", source) >= (int)sizeof(replacement)) return 12;
    int descriptor = open(replacement, O_CREAT | O_EXCL | O_WRONLY, 0600);
    if (descriptor < 0) return 13;
    if (ftruncate(descriptor, before.st_size) != 0) return 14;
    struct timespec times[2] = {before.st_atimespec, before.st_mtimespec};
    if (futimens(descriptor, times) != 0 || close(descriptor) != 0 || rename(replacement, source) != 0) return 15;
  } else if (strstr(source, "modified-source")) {
    int descriptor = open(source, O_WRONLY);
    if (descriptor < 0) return 16;
    if (write(descriptor, "X", 1) != 1) return 17;
    struct timespec times[2] = {before.st_atimespec, before.st_mtimespec};
    times[1].tv_sec -= 60;
    if (futimens(descriptor, times) != 0 || close(descriptor) != 0) return 18;
  } else if (strstr(source, "appended-source")) {
    int descriptor = open(source, O_APPEND | O_WRONLY);
    if (descriptor < 0 || write(descriptor, "X", 1) != 1 || close(descriptor) != 0) return 19;
  }
  puts("{\"format\":{\"format_name\":\"fixture\"},\"streams\":[{\"index\":0,\"codec_type\":\"video\",\"codec_name\":\"h264\",\"bits_per_raw_sample\":\"8\",\"width\":160,\"height\":90}]}");
  return 0;
}
