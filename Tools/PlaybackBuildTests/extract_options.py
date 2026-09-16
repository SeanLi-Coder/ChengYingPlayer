"""Extract initialized option names and literal values from the actual Swift sources."""

import re
from pathlib import Path

root = Path(__file__).resolve().parents[2]
constants = {}
group = None
for line in (root / "iina/MPVOption.swift").read_text().splitlines():
    if match := re.fullmatch(r"  struct (\w+) \{", line):
        group = match[1]
    elif match := re.fullmatch(r'    static let (\w+) = "([^"\\]+)"', line):
        assert group is not None
        constants[f"MPVOption.{group}.{match[1]}"] = match[2]

source = (root / "iina/MPVController.swift").read_text()
source = source.split("  func mpvInit() {", 1)[1].split("  func mpvInitRendering() {", 1)[0]
source = re.sub(r"//[^\n]*", "", source)
references = set(re.findall(r"MPVOption\.\w+\.\w+", source))
assert len(references) >= 40, "The production initialization extraction was unexpectedly small"
assert not references.difference(constants), "Unresolved production MPV option constant"
options = {constants[name]: None for name in references}
for symbol, literal in re.findall(r'setOptionString\((MPVOption\.\w+\.\w+),\s*"([^"\\]*)"', source):
    options[constants[symbol]] = literal
for literal in re.findall(r'setOptionString\("([^"\\]+)"', source):
    options.setdefault(literal, None)
for name, value in sorted(options.items()):
    assert "\t" not in name + (value or "") and "\n" not in name + (value or "")
    print(name + "\t" + ("1" if value is not None else "0") + "\t" + (value or ""))
