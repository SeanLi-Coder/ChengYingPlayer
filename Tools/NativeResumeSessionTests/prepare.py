"""Make exactly one shutdown mutation in a disposable source copy."""
import pathlib
import sys

source, destination, mode = sys.argv[1:]
text = pathlib.Path(source).read_text()
start = text.index("  func shutdown(capturingState:")
end = text.index("\n  private func resetOnWorker()", start)
method = text[start:end]
replacements = {
    "drop-owner": (
        "identity.accepts(request), revision == retiringRevision,\n         generation == retiringGeneration,",
        "identity.accepts(request),"),
    "allow-preroll": (
        "[.playing, .paused, .ended].contains(phase), !preroll,\n         ", ""),
    "drop-cancellation": ("let request = identity.advance(cancel: true)",
                          "let request = identity.advance(cancel: false)"),
    "duplicate-callback": ("capturingState?(result)\n        completion()",
                           "capturingState?(result)\n        capturingState?(result)\n        completion()"),
    "capture-after-reset": ("      let result: NativePlaybackQueryResult",
                            "      resetOnWorker()\n      let result: NativePlaybackQueryResult"),
}
old, new = replacements[mode]
assert method.count(old) == 1, (mode, "mutation landmark mismatch")
method = method.replace(old, new, 1)
pathlib.Path(destination).write_text(text[:start] + method + text[end:])
