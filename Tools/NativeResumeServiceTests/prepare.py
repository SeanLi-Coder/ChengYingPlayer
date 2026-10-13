"""Keep real service code while replacing only the shared configuration boundary."""
from pathlib import Path
import sys


def replace_once(text, old, new):
    if text.count(old) != 1:
        raise ValueError("Control anchor is not unique")
    return text.replace(old, new, 1)


source, destination, control = sys.argv[1:]
text = Path(source).read_text(encoding="utf-8")
text = replace_once(
    text,
    "static let shared = NativePlaybackResumeService(rootURL: Utility.watchLaterURL, defaults: .standard)",
    "static let shared = NativePlaybackResumeService(rootURL: ResumeServiceFixture.root, defaults: ResumeServiceFixture.defaults)",
)
if control == "premature-finish":
    text = replace_once(text, "guard captured else { return }", "guard captured else { complete(nil); return }")
elif control == "overwrite-baseline":
    text = replace_once(text, "if !hasPointOverride { self.point = point }", "self.point = point")
elif control == "ignore-authoritative":
    text = replace_once(text, "if authoritative || point != nil {", "if point != nil {")
elif control == "save-compatibility":
    text = replace_once(text, "guard saveRequested, !finished else { completion(); return }", "guard !finished else { completion(); return }")
elif control == "ignore-kvo":
    text = replace_once(text, """    if let enabled = change?[.newKey] as? NSNumber, !enabled.boolValue {
      store.setResumeEnabled(false)
    }
    store.setResumeEnabled(defaults.bool(forKey: preferenceKey))
""", "    _ = defaults.bool(forKey: preferenceKey)\n")
elif control == "ignore-epochs":
    text = replace_once(text, "recentRecordsEpoch &+= 1", "recentRecordsEpoch &+= 0")
    text = replace_once(text, "progressRecordsEpoch &+= 1", "progressRecordsEpoch &+= 0")
elif control == "duplicate-delivery":
    text = replace_once(text, "resultDelivered = true", "resultDelivered = false")
elif control != "positive":
    raise ValueError("Unknown control")
with Path(destination).open("x", encoding="utf-8") as output:
    output.write(text)
