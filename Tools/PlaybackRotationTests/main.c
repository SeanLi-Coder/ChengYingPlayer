// Exercise rotation cleanup at real libmpv playback teardown boundaries.
#include <dlfcn.h>
#include <limits.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <mpv/client.h>

static void require(bool condition, const char *message)
{
    if (!condition) {
        fprintf(stderr, "FAIL: %s\n", message);
        exit(1);
    }
}

static void checked(int result, const char *message)
{
    if (result < 0) {
        fprintf(stderr, "FAIL: %s: %s\n", message, mpv_error_string(result));
        exit(1);
    }
}

static double now(void)
{
    struct timespec value;
    require(clock_gettime(CLOCK_MONOTONIC, &value) == 0, "Read monotonic clock");
    return value.tv_sec + value.tv_nsec / 1e9;
}

int main(int argc, const char **argv)
{
    require(argc == 5,
            "Usage: PlaybackRotationTests LIBMPV VIDEO unload|after-end eof|stop|replace|resume|playlist");
    bool unsafe = strcmp(argv[3], "unload") == 0;
    require(unsafe || strcmp(argv[3], "after-end") == 0, "Select a cleanup phase");
    bool eof = strcmp(argv[4], "eof") == 0;
    bool replace = strcmp(argv[4], "replace") == 0;
    bool resume = strcmp(argv[4], "resume") == 0;
    bool playlist = strcmp(argv[4], "playlist") == 0;
    require(eof || replace || resume || playlist || strcmp(argv[4], "stop") == 0,
            "Select an exit boundary");
    setvbuf(stdout, NULL, _IONBF, 0);

    Dl_info info;
    char expected[PATH_MAX], actual[PATH_MAX];
    require(realpath(argv[1], expected) && dladdr((void *)mpv_create, &info) &&
            realpath(info.dli_fname, actual) && strcmp(expected, actual) == 0,
            "The selected actual libmpv library is loaded");
    printf("LIBRARY: %s\n", actual);
    printf("CASE: %s rotation cleanup during %s\n", argv[3], argv[4]);

    mpv_handle *player = mpv_create();
    require(player != NULL, "Create real libmpv core");
    const char *options[][2] = {
        {"config", "no"}, {"terminal", "no"}, {"input-terminal", "no"},
        {"input-default-bindings", "no"},
        {"vo", "null"}, {"ao", "null"}, {"hwdec", "no"}, {"idle", "yes"},
        {"keep-open", resume ? "yes" : "no"}, {"loop-file", "no"}, {"video-rotate", "90"},
        {"resume-playback", "no"}, {"save-position-on-quit", "no"}
    };
    for (size_t i = 0; i < sizeof(options) / sizeof(options[0]); i++)
        checked(mpv_set_option_string(player, options[i][0], options[i][1]), options[i][0]);
    checked(mpv_initialize(player), "Initialize real libmpv");
    checked(mpv_request_log_messages(player, "warn"), "Request actual core diagnostics");
    checked(mpv_hook_add(player, 1, "on_unload", 0), "Observe pre-teardown boundary");
    checked(mpv_hook_add(player, 2, "on_after_end_file", 0), "Observe completed teardown");
    if (resume)
        checked(mpv_observe_property(player, 3, "eof-reached", MPV_FORMAT_FLAG),
                "Observe natural EOF while keeping the file open");
    const char *load[] = {"loadfile", argv[2], "replace", NULL};
    checked(mpv_command(player, load), "Load generated test clip");
    if (playlist) {
        const char *append[] = {"loadfile", argv[2], "append", NULL};
        checked(mpv_command(player, append), "Append a second clip for natural playlist advance");
    }

    unsigned loaded = 0, unloaded = 0, finished = 0, ended = 0;
    bool issued_exit = false, success = false, resumed = false, restarted = false;
    double deadline = now() + 20;
    while (now() < deadline) {
        mpv_event *event = mpv_wait_event(player, 0.1);
        if (event->event_id == MPV_EVENT_LOG_MESSAGE) {
            mpv_event_log_message *log = event->data;
            fprintf(stderr, "MPV %s: %s", log->prefix, log->text);
        } else if (event->event_id == MPV_EVENT_FILE_LOADED) {
            loaded++;
            printf("EVENT: file-loaded %u\n", loaded);
            int64_t rotation = 90;
            checked(mpv_set_property(player, "video-rotate", MPV_FORMAT_INT64, &rotation),
                    "Start each loaded file with an active rotation preview");
        } else if (event->event_id == MPV_EVENT_PLAYBACK_RESTART && resume && resumed) {
            restarted = true;
            int64_t rotation = 90;
            checked(mpv_set_property(player, "video-rotate", MPV_FORMAT_INT64, &rotation),
                    "Apply rotation after seeking away from kept-open EOF");
        } else if (event->event_id == MPV_EVENT_PLAYBACK_RESTART &&
                   !eof && !resume && !playlist && !issued_exit) {
            issued_exit = true;
            // Wait for real decoded playback before stopping or replacing it.
            const char *stop[] = {"stop", NULL};
            checked(mpv_command(player, replace ? load : stop), "Request teardown transition");
        } else if (event->event_id == MPV_EVENT_PROPERTY_CHANGE && resume && !resumed) {
            mpv_event_property *property = event->data;
            if (property->format == MPV_FORMAT_FLAG && property->data &&
                *(int *)property->data) {
                require(unloaded == 0 && ended == 0, "Keep-open reaches EOF without unloading");
                resumed = true;
                int pause = 1;
                checked(mpv_set_property(player, "pause", MPV_FORMAT_FLAG, &pause),
                        "Pause while inspecting kept-open EOF");
                int64_t rotation = 0;
                checked(mpv_set_property(player, "video-rotate", MPV_FORMAT_INT64, &rotation),
                        "Refresh rotation while paused at kept-open EOF");
                const char *seek[] = {"seek", "0", "absolute+exact", NULL};
                checked(mpv_command(player, seek), "Seek away from kept-open EOF");
                checked(mpv_set_property_string(player, "keep-open", "no"),
                        "Unload normally at the next natural EOF");
                pause = 0;
                checked(mpv_set_property(player, "pause", MPV_FORMAT_FLAG, &pause),
                        "Resume actual decoding from the beginning");
                printf("RECOVERY: rotation and exact seek from kept-open EOF\n");
            }
        } else if (event->event_id == MPV_EVENT_HOOK) {
            mpv_event_hook *hook = event->data;
            uint64_t id = hook->id;
            bool unloading = strcmp(hook->name, "on_unload") == 0;
            if (unloading) unloaded++;
            else finished++;
            printf("HOOK: %s (%u/%u)\n", hook->name, unloaded, finished);
            if (unloading == unsafe) {
                int64_t rotation = 0;
                checked(mpv_set_property(player, "video-rotate", MPV_FORMAT_INT64, &rotation),
                        "Restore preview rotation through actual libmpv property API");
                printf("ROTATION: restored to zero\n");
            }
            checked(mpv_hook_continue(player, id), "Continue actual playback hook");
        } else if (event->event_id == MPV_EVENT_END_FILE) {
            mpv_event_end_file *end = event->data;
            ended++;
            printf("EVENT: end-file %u reason=%d error=%d\n", ended, end->reason, end->error);
            require(end->error == 0, "Playback exits without a decoder error");
            require(end->reason == ((eof || resume || playlist || ended > 1) ? MPV_END_FILE_REASON_EOF
                                                      : MPV_END_FILE_REASON_STOP),
                    "Playback retains the intended EOF or stop reason");
        }
        require(event->event_id != MPV_EVENT_SHUTDOWN, "The libmpv core stays alive");
        unsigned expected_files = replace || playlist ? 2 : 1;
        if (finished == expected_files && ended == expected_files) {
            success = true;
            break;
        }
    }
    require(success, "Teardown completes before the deadline");
    require(loaded == (replace || playlist ? 2U : 1U) && unloaded == loaded && finished == loaded,
            "Each real file finishes both teardown hooks");
    require(!resume || (resumed && restarted), "Actual decoding restarts after the EOF seek");
    int64_t rotation = -1;
    checked(mpv_get_property(player, "video-rotate", MPV_FORMAT_INT64, &rotation),
            "Read final rotation from the live core");
    require(rotation == 0, "Cleanup restores rotation for the next file");
    mpv_terminate_destroy(player);
    printf("PASS: %s rotation cleanup during %s\n", argv[3], argv[4]);
    return 0;
}
