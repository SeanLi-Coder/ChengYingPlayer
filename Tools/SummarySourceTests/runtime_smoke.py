"""Check the pinned summary architecture on Metal using tiny random weights.

Run with the optional AI runtime's Python, not the frozen helper build environment.
This validates architecture/device compatibility, not the quality or performance
of the full 27B model. No model files or network access are used.
"""

from __future__ import annotations

import json
import os
import tempfile
from pathlib import Path

os.environ["HF_HUB_OFFLINE"] = "1"
os.environ["TRANSFORMERS_OFFLINE"] = "1"
os.environ["HF_HUB_DISABLE_TELEMETRY"] = "1"
os.environ["PYTORCH_ENABLE_MPS_FALLBACK"] = "1"
os.environ["HF_DEACTIVATE_ASYNC_LOAD"] = "1"


def main() -> None:
    import torch
    import transformers

    root = Path(__file__).resolve().parents[2]
    manifest = json.loads((root / "Tools/SubtitleToolsHelper/assets.json").read_text())
    requirements = manifest["runtime"]["requirements"]
    for name, version in (("torch", torch.__version__.split("+")[0]), ("transformers", transformers.__version__)):
        assert any(row.startswith(f"{name}=={version} ") for row in requirements), f"Use the pinned {name} runtime"
    assert torch.backends.mps.is_available(), "This check requires Apple Metal"
    config = transformers.AutoConfig.for_model(
        "qwen3_5",
        text_config={
            "hidden_size": 64, "intermediate_size": 128, "num_hidden_layers": 4,
            "num_attention_heads": 4, "num_key_value_heads": 2, "head_dim": 16,
            "linear_num_key_heads": 4, "linear_num_value_heads": 4,
            "linear_key_head_dim": 16, "linear_value_head_dim": 16, "vocab_size": 256,
            "layer_types": ["linear_attention", "linear_attention", "linear_attention", "full_attention"],
        },
        vision_config={"hidden_size": 64, "out_hidden_size": 64, "intermediate_size": 128,
                       "num_heads": 4, "depth": 1},
    )
    # Official weights include the vision module and nested language-model key
    # prefixes. Check the real loading conversion, not only random construction.
    full = transformers.AutoModelForMultimodalLM.from_config(config)
    with tempfile.TemporaryDirectory(prefix="chengying-tiny-summary-model-") as folder:
        full.save_pretrained(folder, safe_serialization=True)
        del full
        model, loading = transformers.AutoModelForCausalLM.from_pretrained(
            folder, local_files_only=True, trust_remote_code=False, use_safetensors=True,
            dtype=torch.bfloat16, device_map={"": "mps"}, attn_implementation="sdpa",
            output_loading_info=True,
        )
    assert not loading.get("missing_keys"), "Text weights were not restored from the multimodal checkpoint"
    assert not loading.get("mismatched_keys"), "Checkpoint conversion changed text tensor shapes"
    model.to("mps").eval()
    prompt = torch.tensor([[2, 3, 4, 5]], device="mps")
    with torch.inference_mode():
        result = model.generate(input_ids=prompt, attention_mask=torch.ones_like(prompt),
                                max_new_tokens=4, do_sample=False, pad_token_id=0, eos_token_id=None)
    torch.mps.synchronize()
    assert result.shape == (1, 8), "Cached hybrid-layer generation did not produce all requested tokens"
    assert next(model.parameters()).device.type == "mps"
    assert next(model.parameters()).dtype == torch.bfloat16
    print("Tiny random Qwen hybrid BF16 Metal generation passed; full-model quality and speed were not evaluated")


if __name__ == "__main__":
    main()
