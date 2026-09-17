"""Fail closed if the actual application's ICC ordering diverges from the live test."""

import re
from pathlib import Path


def verify(video: str, layer: str) -> None:
    start = video.index("private func setICCProfile() {")
    end = video.index("let sdrColorSpace =", start)
    body = re.sub(r"//[^\n]*", "", video[start:end])
    expected = re.compile(
        r"player\.mpv\.setFlag\(MPVOption\.GPURendererOptions\.iccProfileAuto,\s*true\)"
        r"\s*if !videoLayer\.setRenderICCProfile\(screenColorSpace\)\s*\{"
        r"\s*player\.mpv\.setFlag\(MPVOption\.GPURendererOptions\.iccProfileAuto,\s*false\)"
    )
    if not expected.search(body):
        raise ValueError(
            "The application must enable ICC before submitting its profile and disable it on failure."
        )
    start = layer.index("func setRenderICCProfile(_ profile: NSColorSpace) -> Bool {")
    end = layer.index("// MARK: - Utils", start)
    bridge = layer[start:end]
    if not re.search(
        r"let result = mpv_render_context_set_parameter\(renderContext, params\)"
        r"\s*guard result >= 0 else\s*\{",
        bridge,
    ):
        raise ValueError("The production bridge must check the actual ICC API result.")


root = Path(__file__).resolve().parents[2]
video = (root / "iina/VideoView.swift").read_text()
layer = (root / "iina/ViewLayer.swift").read_text()
verify(video, layer)

# Tiny source-boundary mutations prove this is not an always-passing text check.
for changed_video, changed_layer in (
    (
        video.replace(
            "if !videoLayer.setRenderICCProfile(screenColorSpace)",
            "if !videoLayer.setRenderICCProfileAfterDraw(screenColorSpace)",
        ),
        layer,
    ),
    (video, layer.replace("guard result >= 0 else", "guard result >= -100 else")),
):
    try:
        verify(changed_video, changed_layer)
    except (ValueError, IndexError):
        continue
    raise AssertionError(
        "The production ICC wiring guard accepted a regressed source boundary."
    )
print(
    "PASS: Actual Swift enables ICC before profile submission and propagates API failure (source-wiring check, not a compiled Swift UI test)."
)
