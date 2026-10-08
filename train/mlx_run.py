"""在 Kev 的虚拟环境里跑 mlx_lm 的命令（lora / server / generate）。
这个环境的 Python 来自 Anaconda，带的是 MPICH；MLX 默认先找 MPI，发现不是 Open MPI 就直接退出。
单机训练用不到分布式，这里先把后端固定成 ring（单机时就是一个只有自己的组）。
用法：~/kev/.venv/bin/python mlx_run.py lora --model … --train …
"""
import os, runpy, sys
# 让 MLX 找不到 MPI（库名指向一个不存在的文件），单机就用自己一个进程
os.environ.setdefault("MLX_MPI_LIBNAME", "libmpi-not-used.dylib")
import mlx.core as mx

# 24GB 的 Mac 上和别的程序共用内存：给 MLX 设上限，超出时报错退出，而不是把整台机器拖到卡死重启
# （2026-10-08 01:33 训练和 Ollama 同时跑，内存耗尽后机器重启过一次）。
LIMIT_GB = float(os.environ.get("MLX_LIMIT_GB", "14"))
mx.set_memory_limit(int(LIMIT_GB * (1 << 30)))
mx.set_cache_limit(1 << 30)

_init = mx.distributed.init
mx.distributed.init = lambda *args, **kwargs: _init(strict=False, backend="ring")
# Qwen3.5 的 32 层里有 24 层是线性注意力（Gated DeltaNet）。mlx_lm 训练时（module.training）不用 Metal 内核，
# 改走逐个 token 的循环（内核没有反向传播）。LoRA 只挂在最后 N 层时，前面那些层不训练、也不需要反向传播，
# 这里让它们照样走内核。实测（M4 Pro，--num-layers 8，同样数据和种子）：loss 完全一致，但只快约 5%。
# 训练慢的大头在被训练的那几层的反向传播：速度大致和 --num-layers 里线性注意力层的数量成反比
# （16 层 0.073、8 层 0.139、5 层 0.195 步/秒），所以真正管用的是少挂几层。
if os.environ.get("MLX_FAST_FROZEN", "1") == "1":
    from mlx_lm.models import qwen3_5
    from mlx_lm.tuner import utils as tuner_utils

    _call = qwen3_5.GatedDeltaNet.__call__

    def _fast_call(self, *args, **kwargs):
        if getattr(self, "_frozen_kernel", False) and self._training:
            self._training = False
            try:
                return _call(self, *args, **kwargs)
            finally:
                self._training = True
        return _call(self, *args, **kwargs)

    qwen3_5.GatedDeltaNet.__call__ = _fast_call
    _to_lora = tuner_utils.linear_to_lora_layers

    def _to_lora_marking(model, num_layers, *args, **kwargs):
        result = _to_lora(model, num_layers, *args, **kwargs)
        layers = model.layers
        frozen = layers if num_layers <= 0 else layers[: max(0, len(layers) - num_layers)]
        if num_layers > 0:
            marked = 0
            for layer in frozen:
                if hasattr(layer, "linear_attn"):
                    layer.linear_attn._frozen_kernel = True
                    marked += 1
            print(f"[mlx_run] {marked} frozen linear-attention layers use the Metal kernel during training", flush=True)
        return result

    tuner_utils.linear_to_lora_layers = _to_lora_marking

command = sys.argv.pop(1)
sys.argv[0] = f"mlx_lm.{command}"
if command == "server":
    # mlx_lm 0.31.3 的服务有个 bug：ModelProvider.load 先把 "default_model" 换成模型路径，再拿换过的路径去查适配器表，
    # 永远查不到，--adapter-path 等于没给（2026-10-08 S1、U1 的评测因此测的都是没微调的底座）。这里改成用原来的键去查。
    import mlx_lm.server as server

    def _load(self, model_path, adapter_path=None, draft_model_path=None):
        key = model_path
        model_path = self._model_map.get(key, key)
        adapter_path = self._adapter_map.get(key, adapter_path)
        draft_model_path = self._draft_model_map.get(draft_model_path, draft_model_path)
        model_key = (model_path, adapter_path, draft_model_path)
        if self.model_key != model_key:
            self._load(*model_key)
            # Base 模型的分词器只把 <|endoftext|> 当结束符；微调教的是对话格式，回答完输出 <|im_end|>。
            # 不加的话模型写完 JSON 还会一直往下写到 max_tokens（2026-10-08 SU 的评测 42 条全被截断）。
            self.tokenizer.add_eos_token("<|im_end|>")
        return self.model, self.tokenizer

    server.ModelProvider.load = _load
    print(f"[mlx_run] server adapter lookup patched", flush=True)
    server.main()
else:
    runpy.run_module(f"mlx_lm.{command}", run_name="__main__")
