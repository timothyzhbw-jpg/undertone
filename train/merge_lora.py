"""把 MLX 训练出的 LoRA 增量直接加到 Hugging Face 原版（bf16）权重上，得到一个完整的 HF 格式模型目录，给 Ollama 导入。

  ~/kev/.venv/bin/python train/merge_lora.py runs/SU models/undertone-su-hf

为什么不用 mlx_lm.fuse：MLX 保存的权重是它自己的布局（qwen3_5 的 sanitize 会转置 conv1d、给零中心的 RMSNorm 加 1），
直接给别的工具读会悄悄出错。LoRA 只挂在线性层上，线性层两边布局一样，所以在原版权重上加增量最稳：
  W' = W + scale · (lora_a @ lora_b)ᵀ      lora_a: [in, r]，lora_b: [r, out]，W: [out, in]
训练时底座是 4 bit 量化版（QLoRA），合并到原版 bf16 权重上是通常的做法。
"""
import glob, json, shutil, sys
from pathlib import Path

import torch
from safetensors import safe_open
from safetensors.torch import load_file, save_file

adapter_dir, out_dir = Path(sys.argv[1]), Path(sys.argv[2])
base = Path(glob.glob(str(Path.home() / ".cache/huggingface/hub/models--Qwen--Qwen3.5-4B-Base/snapshots/*/"))[0])
scale = json.load((adapter_dir / "adapter_config.json").open())["lora_parameters"]["scale"]

deltas = {}
with safe_open(str(adapter_dir / "adapters.safetensors"), "pt") as f:
    for key in f.keys():
        if not key.endswith(".lora_a"):
            continue
        module = key[: -len(".lora_a")]
        a = f.get_tensor(key).float()                       # [in, r]
        b = f.get_tensor(module + ".lora_b").float()        # [r, out]
        hf = module.replace("language_model.model.", "model.language_model.", 1) + ".weight"
        deltas[hf] = scale * (a @ b).T                      # [out, in]

out_dir.mkdir(parents=True, exist_ok=True)
for item in base.iterdir():
    if not item.name.endswith(".safetensors"):
        shutil.copy(item.resolve(), out_dir / item.name)

applied = 0
for shard in sorted(base.glob("*.safetensors")):
    tensors = load_file(str(shard.resolve()))
    for name, delta in deltas.items():
        if name in tensors:
            w = tensors[name]
            assert w.shape == delta.shape, (name, w.shape, delta.shape)
            tensors[name] = (w.float() + delta).to(w.dtype)
            applied += 1
    save_file(tensors, str(out_dir / shard.name), metadata={"format": "pt"})
    print(f"{shard.name}: done", flush=True)

assert applied == len(deltas), f"只合并了 {applied}/{len(deltas)} 个"
print(f"合并了 {applied} 个线性层（scale {scale}）→ {out_dir}")
