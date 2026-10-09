# Fast mode: the fine-tuned model in Ollama

Undertone's **Fast** model choice uses a local model fine-tuned only for reading subtext. It needs a short prompt (about 400 tokens) instead of the standard model's few-shot prompt (several thousand), so each message is faster. "Check before you send" and emoji images still go to the standard model.

The model isn't published anywhere yet, so you build it on your own Mac:

1. **Train** the LoRA adapter as described in [`../RESULTS.md`](../RESULTS.md) (`train/run_all.sh`), or use an adapter you already have in `train/runs/<arm>/`.
2. **Merge** the adapter into the original Hugging Face weights of Qwen3.5-4B-Base:

   ```bash
   ~/kev/.venv/bin/python train/merge_lora.py train/runs/SU train/models/undertone-su-hf
   ```

   The script adds the LoRA increments to the bf16 linear layers. It deliberately doesn't use `mlx_lm.fuse`: MLX stores some Qwen3.5 tensors in its own layout (conv1d axis order, norm weights shifted by 1), which other tools would read wrongly.
3. **Import** into Ollama, quantized to 4-bit (about 3.5 GB). Run this from inside the merged directory so the paths are local:

   ```bash
   cd train/models/undertone-su-hf
   sed 's|^FROM .*|FROM .|' ../../ollama/Modelfile.subtext > Modelfile
   ollama create undertone-subtext -q q4_K_M -f Modelfile
   ```

   The [Modelfile](Modelfile.subtext) uses the same Qwen chat format as training: an empty thinking block, and `<|im_end|>` as the stop token.
4. In Undertone's Settings → Analysis engine → Local Ollama, choose **Fast: Undertone fine-tuned model**.
