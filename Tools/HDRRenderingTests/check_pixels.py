"""Check real framebuffer output from the generated neutral-luminance fixtures."""

import sys
from itertools import pairwise
from pathlib import Path


def read_bars(path: Path) -> list[tuple[int, int, int]]:
    data = path.read_bytes()
    header = b"P6\n128 64\n255\n"
    assert data.startswith(header), f"Unexpected framebuffer format: {path.name}"
    pixels = data[len(header):]
    assert len(pixels) == 128 * 64 * 3, "Full framebuffer must be present"
    bars = []
    for bar in range(8):
        offset = (32 * 128 + bar * 16 + 8) * 3
        color = tuple(pixels[offset:offset + 3])
        assert max(color) - min(color) <= 2, f"Neutral {path.stem} patch became tinted: {color}"
        bars.append(color)
    values = [color[0] for color in bars]
    assert values[0] <= 2, f"Black lifted unexpectedly: {values}"
    assert all(a <= b for a, b in pairwise(values)), f"Tone response is not monotonic: {values}"
    assert all(a < b for a, b in pairwise(values[:6])), f"Midtone detail clipped: {values}"
    assert 70 <= values[3] <= 200, f"50-nit midtone is not usable SDR: {values}"
    assert values[-1] >= 210, f"Highlight output is missing: {values}"
    print(f"PASS: {path.stem} real neutral framebuffer bars: {bars}")
    return bars


def main() -> None:
    assert len(sys.argv) == 4, "Usage: check_pixels.py SDR_PPM PQ_PPM HLG_PPM"
    srgb, pq, hlg = [read_bars(Path(path)) for path in sys.argv[1:]]
    expected_srgb = [0, 15, 63, 136, 186, 255, 255, 255]
    assert all(abs(color[0] - expected) <= 3 for color, expected in zip(srgb, expected_srgb)), \
        f"SDR no longer preserves the generated sRGB transfer response: {srgb}"
    assert pq != hlg and pq != srgb and hlg != srgb, "Distinct transfer metadata must affect real pixels"
    print("PASS: SDR/PQ/HLG real transfer responses remain distinct, neutral and unclipped in midtones")


if __name__ == "__main__":
    main()
