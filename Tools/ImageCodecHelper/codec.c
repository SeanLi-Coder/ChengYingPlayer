// SPDX-License-Identifier: GPL-3.0-only
// Lossless, local-only WebP encoding from a bounded RGBA frame directory.
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <limits.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include <webp/encode.h>
#include <webp/mux.h>

#define MAX_FRAMES 10000U
#define MAX_FRAME_BYTES (256U * 1024U * 1024U)
#define MAX_TOTAL_BYTES (8ULL * 1024ULL * 1024ULL * 1024ULL)
#define MAX_ENCODED_BYTES (512U * 1024U * 1024U)
#define MAX_ICC_BYTES (4U * 1024U * 1024U)
#define MAX_DURATION 16777215U

static volatile sig_atomic_t cancelled = 0;
static void interrupt_encoding(int signum) { (void)signum; cancelled = 1; }
static int progress(int percent, const WebPPicture *picture) {
  (void)percent; (void)picture; return !cancelled;
}

static bool unchanged(const struct stat *before, const struct stat *after) {
  return before->st_dev == after->st_dev && before->st_ino == after->st_ino &&
    before->st_size == after->st_size &&
    before->st_mtimespec.tv_sec == after->st_mtimespec.tv_sec &&
    before->st_mtimespec.tv_nsec == after->st_mtimespec.tv_nsec &&
    before->st_ctimespec.tv_sec == after->st_ctimespec.tv_sec &&
    before->st_ctimespec.tv_nsec == after->st_ctimespec.tv_nsec;
}

static uint8_t *read_input(int directory, const char *name, size_t length) {
  int fd = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
  struct stat before, after;
  uint8_t *bytes = NULL;
  if (fd < 0 || fstat(fd, &before) || !S_ISREG(before.st_mode) ||
      before.st_size < 0 || (uint64_t)before.st_size != length) goto done;
  bytes = malloc(length ? length : 1);
  if (!bytes) goto done;
  size_t offset = 0;
  while (offset < length && !cancelled) {
    ssize_t count = read(fd, bytes + offset, length - offset);
    if (count < 0 && errno == EINTR) continue;
    if (count <= 0) break;
    offset += (size_t)count;
  }
  if (offset != length || fstat(fd, &after) || !unchanged(&before, &after)) {
    free(bytes); bytes = NULL;
  }
done:
  if (fd >= 0) close(fd);
  return bytes;
}

static bool numbers(char *line, uint64_t *values, size_t count) {
  char *cursor = line;
  for (size_t i = 0; i < count; ++i) {
    while (*cursor == ' ' || *cursor == '\t') ++cursor;
    if (*cursor < '0' || *cursor > '9') return false;
    errno = 0;
    char *end = NULL;
    values[i] = strtoull(cursor, &end, 10);
    if (errno || end == cursor) return false;
    cursor = end;
    if (i + 1 < count && *cursor != ' ' && *cursor != '\t') return false;
  }
  while (*cursor == ' ' || *cursor == '\t') ++cursor;
  if (*cursor == '\r') ++cursor;
  if (*cursor == '\n') ++cursor;
  return *cursor == '\0';
}

static bool read_line(FILE *file, char *line, size_t capacity) {
  size_t length = 0;
  int byte;
  while ((byte = fgetc(file)) != EOF) {
    if (byte == 0 || byte > 127 || length + 1 >= capacity) return false;
    line[length++] = (char)byte;
    if (byte == '\n') break;
  }
  line[length] = '\0';
  return length > 0 && !ferror(file);
}

static bool split_path(const char *path, char **directory, const char **name) {
  if (path[0] != '/' || strlen(path) >= PATH_MAX) return false;
  const char *slash = strrchr(path, '/');
  if (!slash || !slash[1] || !strcmp(slash + 1, ".") || !strcmp(slash + 1, "..")) return false;
  *directory = strndup(path, slash == path ? 1 : (size_t)(slash - path));
  *name = slash + 1;
  return *directory != NULL;
}

static bool publish_output(const char *path, const WebPData *data) {
  char *directory = NULL;
  const char *name = NULL;
  if (!split_path(path, &directory, &name)) return false;
  size_t length = strlen(directory) + 32;
  char *temporary = malloc(length);
  if (!temporary) { free(directory); return false; }
  snprintf(temporary, length, "%s/.chengying-webp-XXXXXX", directory);
  int fd = mkstemp(temporary);
  const bool created = fd >= 0;
  bool success = false;
  if (fd < 0) goto done;
  size_t offset = 0;
  while (offset < data->size && !cancelled) {
    ssize_t count = write(fd, data->bytes + offset, data->size - offset);
    if (count < 0 && errno == EINTR) continue;
    if (count <= 0) break;
    offset += (size_t)count;
  }
  if (offset == data->size && !cancelled && fsync(fd) == 0 && close(fd) == 0) {
    fd = -1;
    // link publishes only if the requested destination does not exist.
    success = link(temporary, path) == 0;
    if (!success && (errno == ENOTSUP || errno == EPERM || errno == EOPNOTSUPP)) {
      // exFAT has no hard links; Darwin's exclusive rename still never replaces.
      success = renamex_np(temporary, path, RENAME_EXCL) == 0;
    }
  }
done:
  if (fd >= 0) close(fd);
  if (created) unlink(temporary);
  free(temporary); free(directory);
  return success;
}

static int encode(const char *manifest_path, const char *output_path) {
  const char *failure = "Invalid or unsupported image manifest.";
  int result = 1, directory_fd = -1, manifest_fd = -1;
  char *directory = NULL;
  const char *manifest_name = NULL;
  FILE *manifest = NULL;
  struct stat before, after;
  uint64_t fields[5];
  uint32_t *durations = NULL;
  uint8_t *icc = NULL;
  WebPMux *mux = NULL;
  WebPData encoded = {NULL, 0}, output = {NULL, 0};
  WebPMemoryWriter writer;
  WebPMemoryWriterInit(&writer);
  char line[160];
  if (!split_path(manifest_path, &directory, &manifest_name)) goto done;
  directory_fd = open(directory, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
  if (directory_fd < 0) goto done;
  manifest_fd = openat(directory_fd, manifest_name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
  if (manifest_fd < 0 || fstat(manifest_fd, &before) || !S_ISREG(before.st_mode) ||
      before.st_size <= 0 || before.st_size > 120000) goto done;
  manifest = fdopen(manifest_fd, "r");
  if (!manifest) goto done;
  manifest_fd = -1;
  if (!read_line(manifest, line, sizeof(line)) || strcmp(line, "CHENGYING_WEBP_1\n") ||
      !read_line(manifest, line, sizeof(line)) || !numbers(line, fields, 5)) goto done;
  const uint64_t width = fields[0], height = fields[1], count = fields[2];
  const uint64_t loop_count = fields[3], icc_size = fields[4];
  if (!width || !height || width > WEBP_MAX_DIMENSION || height > WEBP_MAX_DIMENSION ||
      !count || count > MAX_FRAMES || loop_count > 65535 || icc_size > MAX_ICC_BYTES) goto done;
  const uint64_t frame_bytes = width * height * 4;
  if (frame_bytes > MAX_FRAME_BYTES || frame_bytes * count > MAX_TOTAL_BYTES) {
    failure = "Image exceeds the safe encoding memory budget."; goto done;
  }
  durations = calloc((size_t)count, sizeof(*durations));
  if (!durations) goto done;
  uint64_t total_time = 0;
  for (size_t i = 0; i < count; ++i) {
    uint64_t duration;
    if (!read_line(manifest, line, sizeof(line)) || !numbers(line, &duration, 1) ||
        duration > MAX_DURATION || (count > 1 && !duration) ||
        (count == 1 && duration != 0)) goto done;
    total_time += duration;
    if (total_time > INT_MAX) goto done;
    durations[i] = (uint32_t)duration;
  }
  if (fgetc(manifest) != EOF || ferror(manifest) ||
      fstat(fileno(manifest), &after) || !unchanged(&before, &after)) goto done;
  fclose(manifest); manifest = NULL;
  failure = "The local image data is missing, damaged, or changed.";
  if (icc_size && !(icc = read_input(directory_fd, "profile.icc", (size_t)icc_size))) goto done;
  WebPConfig config;
  if (!WebPConfigInit(&config)) goto done;
  config.lossless = 1;
  config.quality = 100;
  config.method = 6;
  config.exact = 1;
  if (!WebPValidateConfig(&config)) goto done;
  if (count > 1) {
    mux = WebPMuxNew();
    const WebPMuxAnimParams params = {0, (int)loop_count};
    if (!mux || WebPMuxSetCanvasSize(mux, (int)width, (int)height) != WEBP_MUX_OK ||
        WebPMuxSetAnimationParams(mux, &params) != WEBP_MUX_OK) goto done;
  }
  uint64_t encoded_budget = 128 + icc_size;
  for (size_t i = 0; i < count && !cancelled; ++i) {
    char filename[32];
    snprintf(filename, sizeof(filename), "frame-%06zu.rgba", i);
    uint8_t *rgba = read_input(directory_fd, filename, (size_t)frame_bytes);
    if (!rgba) goto done;
    WebPPicture picture;
    if (!WebPPictureInit(&picture)) { free(rgba); goto done; }
    picture.use_argb = 1;
    picture.width = (int)width;
    picture.height = (int)height;
    picture.progress_hook = progress;
    if (!WebPPictureImportRGBA(&picture, rgba, (int)(width * 4))) {
      WebPPictureFree(&picture); free(rgba); goto done;
    }
    free(rgba);
    failure = "Lossless WebP encoding failed.";
    picture.writer = WebPMemoryWrite;
    picture.custom_ptr = &writer;
    const bool success = WebPEncode(&config, &picture) != 0;
    WebPPictureFree(&picture);
    if (!success) goto done;
    // Include conservative container/chunk padding before copying into the mux.
    encoded_budget += writer.size + 64;
    if (encoded_budget > MAX_ENCODED_BYTES) {
      failure = "Compressed image exceeds the safe output memory budget.";
      goto done;
    }
    if (count > 1) {
      WebPMuxFrameInfo frame = {0};
      frame.bitstream.bytes = writer.mem;
      frame.bitstream.size = writer.size;
      frame.duration = (int)durations[i];
      frame.id = WEBP_CHUNK_ANMF;
      frame.dispose_method = WEBP_MUX_DISPOSE_NONE;
      frame.blend_method = WEBP_MUX_NO_BLEND;
      if (WebPMuxPushFrame(mux, &frame, 1) != WEBP_MUX_OK) goto done;
      WebPMemoryWriterClear(&writer);
      WebPMemoryWriterInit(&writer);
    }
    printf("FRAME %zu %" PRIu64 "\n", i + 1, count);
    fflush(stdout);
  }
  if (cancelled) goto done;
  if (count == 1) {
    encoded.bytes = writer.mem; encoded.size = writer.size;
    writer.mem = NULL; writer.size = 0; writer.max_size = 0;
    mux = WebPMuxCreate(&encoded, 0);
    if (!mux) goto done;
  }
  if (cancelled) goto done;
  if (icc) {
    WebPData profile = {icc, (size_t)icc_size};
    if (WebPMuxSetChunk(mux, "ICCP", &profile, 0) != WEBP_MUX_OK) goto done;
  }
  if (WebPMuxAssemble(mux, &output) != WEBP_MUX_OK || !output.size ||
      output.size > MAX_ENCODED_BYTES || cancelled) goto done;
  failure = "Cannot create the output file; it may already exist.";
  if (!publish_output(output_path, &output)) goto done;
  printf("DONE %zu\n", output.size);
  result = 0;
done:
  if (result) fprintf(stderr, "%s\n", cancelled ? "Image encoding cancelled." : failure);
  if (manifest) fclose(manifest);
  if (manifest_fd >= 0) close(manifest_fd);
  if (directory_fd >= 0) close(directory_fd);
  WebPMuxDelete(mux);
  WebPDataClear(&encoded); WebPDataClear(&output);
  WebPMemoryWriterClear(&writer);
  free(icc); free(durations); free(directory);
  // A completed publication is the commit point. The caller still checks its own
  // cancellation token before moving this private result into the user's folder.
  return result == 0 ? 0 : (cancelled ? 130 : result);
}

int main(int argc, char **argv) {
  if (argc == 2 && !strcmp(argv[1], "--version")) {
    const int version = WebPGetEncoderVersion();
    printf("ChengYing Image Codec 1; libwebp %d.%d.%d\n", version >> 16,
      (version >> 8) & 255, version & 255);
    return 0;
  }
  if (argc != 4 || strcmp(argv[1], "encode")) {
    fprintf(stderr, "Usage: chengying-image-codec encode <absolute-manifest-path> <absolute-output-path>\n");
    return 2;
  }
  struct sigaction action = {0};
  action.sa_handler = interrupt_encoding;
  sigemptyset(&action.sa_mask);
  sigaction(SIGTERM, &action, NULL);
  sigaction(SIGINT, &action, NULL);
  signal(SIGPIPE, SIG_IGN);
  return encode(argv[2], argv[3]);
}
