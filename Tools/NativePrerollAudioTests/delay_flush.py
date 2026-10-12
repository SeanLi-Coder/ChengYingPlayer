"""Delay only acknowledgement of actual asynchronous renderer flush callbacks."""
import pathlib
import sys

source = pathlib.Path(sys.argv[1]).read_text()
needle = """        callbackLock.lock()
        pendingVideoFlushes -= 1
        callbackLock.unlock()
        videoFlushes.leave()"""
if source.count(needle) != 1:
    raise SystemExit("Expected exactly one real video flush completion body")
replacement = """        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.3) { [self] in
          callbackLock.lock()
          pendingVideoFlushes -= 1
          callbackLock.unlock()
          videoFlushes.leave()
        }"""
pathlib.Path(sys.argv[2]).write_text(source.replace(needle, replacement))
