"""Create exact single-purpose controls in the caller's owned artifact directory."""
from pathlib import Path
import sys


def replace_once(text, old, new):
    if text.count(old) != 1:
        raise ValueError("Control anchor is not unique")
    return text.replace(old, new, 1)


source, destination, control = sys.argv[1:]
text = Path(source).read_text(encoding="utf-8")
if control == "bypass-final-gate":
    text = replace_once(
        text,
        "guard let rejection = policy.rejection(for: ticket) else {",
        "guard let rejection = Optional<NativePlaybackResumeResult>.none else {",
    )
elif control == "private-fields":
    text = replace_once(
        text,
        'return Data("start=\\(position == 0 ? 0.0 : position)\\nspeed=\\(speed)\\n".utf8)',
        'return Data("start=\\(position == 0 ? 0.0 : position)\\nspeed=\\(speed)\\nvolume=70\\n".utf8)',
    )
elif control == "overwrite-unknown":
    text = replace_once(
        text,
        "if fstatat(directory, name, &status, AT_SYMLINK_NOFOLLOW) == 0 { return .conflict }",
        "if fstatat(directory, name, &status, AT_SYMLINK_NOFOLLOW) == 0 { continue }",
    )
    text = replace_once(
        text,
        "linkat(directory, temporary, directory, ticket.digest, 0)",
        "renameat(directory, temporary, directory, ticket.digest)",
    )
elif control != "positive":
    raise ValueError("Unknown control")
with Path(destination).open("x", encoding="utf-8") as output:
    output.write(text)
