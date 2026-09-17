"""Compile the current production layout methods, without duplicating their implementation."""

from pathlib import Path
import re
import sys

root, output = map(Path, sys.argv[1:])
source = (root / "iina/MainWindowController.swift").read_text()


def block(text, marker):
    start = text.index(marker)
    opening = text.index("{", start)
    depth = 1
    offset = opening + 1
    while depth:
        depth += (text[offset] == "{") - (text[offset] == "}")
        offset += 1
    return text[start:offset]


methods = [block(source, "private func " + name) for name in (
    "setupOSCToolbarButtons(", "setupOnScreenController(", "setupSidebarPanelLayout(", "updateEdgeControlsLayout(",
)]
methods = [method.replace("private func ", "func ", 1) for method in methods]
methods.append(block(source, "var minSize:") if "var minSize:" in source else block(source, "var minSize "))
constants = source[source.index("fileprivate let isMacOS11"):source.index("// The minimum distance")]
constants = constants.replace("fileprivate ", "")
style = block((root / "iina/OSCToolbarButton.swift").read_text(), "static func setStyle(")
utility = block((root / "iina/Utility.swift").read_text(), "static func quickConstraints(")
preference = (root / "iina/Preference.swift").read_text()
toolbar = block(preference, "enum ToolBarButton:")
# Fixture symbols avoid depending on the full application's asset catalog.
image = block(toolbar, "func image()")
toolbar = toolbar.replace(image, 'func image() -> NSImage { NSImage(systemSymbolName: "circle", accessibilityDescription: nil)! }')
prefix = (root / "Tools/PlayerChromeIntegrationTests/Controller.swift").read_text()
playlist_source = (root / "iina/PlaylistViewController.swift").read_text()
playlist = block(playlist_source, "private func installSortControls(")
playlist = playlist.replace("private func ", "func ", 1)
prefix = prefix.replace("// PRODUCTION_PLAYLIST_COMPACT_PROPERTY", block(playlist_source, "var useCompactTabHeight ="))
prefix = prefix.replace("// PRODUCTION_PLAYLIST_SHIFT_PROPERTY", block(playlist_source, "var downShift:"))
row_height = re.search(r"(?m)^    playlistTableView\.rowHeight = .+$", playlist_source).group(0)
playlist += "\nfunc applyProductionTableMetrics() {\n" + row_height + "\n}\n"
generated = (
    "import Cocoa\n" + constants + "\nextension Preference {\n" + toolbar + "\n}\n"
    + "enum OSCToolbarButton {\n" + style + "\n}\n"
    + "enum Utility {\n" + utility + "\n}\n"
    + prefix + "\nextension LayoutController {\n" + "\n".join(methods) + "\n}\n"
    + "extension PlaylistLayoutController {\n" + playlist + "\n}\n"
)
output.write_text(generated)
print("Extracted and retained all four current production layout methods and the real toolbar sizing policy.")
