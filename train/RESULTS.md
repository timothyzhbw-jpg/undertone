# Fine-tuning a local model: overnight results (2026-10-08)

**Question.** Can a small local model learn the cross-cultural reading task well enough to drop the long few-shot prompt, and does it need human labels to get there?

**Setup.** One Mac (M4 Pro, 24 GB), MLX 0.32.2, mlx-lm 0.31.3. QLoRA on a 4-bit copy of **Qwen3.5-4B-Base** (`mlx_lm.convert -q`), LoRA rank 8 on the last 5 of 32 layers, `--mask-prompt`, batch 1 with 4-step gradient accumulation, learning rate 1e-4. The fine-tuned model gets a short system prompt ([`presets/subtext.ft.zh.json`](../presets/subtext.ft.zh.json)) and no examples. It is evaluated through the app's own code path (`Undertone --eval`, same parser and safety nets) against a local `mlx_lm.server`.

## Data

[`pool.jsonl`](pool.jsonl) holds 288 hand-written English messages across trade, workplace, campus, social and safety scenarios. Each has a gold reading, the signals that must be raised, and a best response. None overlap the evaluation sets (checked by word-set similarity against the development set, the held-out set and the prompt's examples).

| Arm | How the 288 messages were labelled | Training items |
|---|---|---|
| **S** (supervised) | Gold reading, signals and response from the pool. The prompted model writes the explanation and reply *given* the gold answer ([`gen_labels.py`](gen_labels.py) `S`). | 255 (+28 validation) |
| **U** (self-training) | No gold labels at all. The prompted model answers each message 3 times at temperature 0.8; only items where all 3 readings agree are kept ([`gen_labels.py`](gen_labels.py) `U`). | 145 (+14 validation) |
| **SU** | S and U training sets combined | 400 |

A useful by-product: since every pool item has a gold label *and* three independent samples, the pool doubles as a 288-item test of the prompted model ([`pool_vote.py`](pool_vote.py)):

| Prompted qwen3.5:4b on the pool | Accuracy |
|---|---|
| One sample (temperature 0.8) | 580/864 (67%) |
| Majority of 3 | 203/288 (70%) |
| Items where all 3 agree (what arm U trains on) | 146/167 (87%) |

Weakest readings: *just being polite* 29%, *joking* 46%, *a polite no* 55%, *not happy* 57%. Strongest: *red flag* 100%, *waiting on you* 88%, *not decided yet* 86%.

## Results

Reading accuracy on the development set (40 scored items) and the held-out set (28 scored items, not looked at while tuning), plus safety signals summed over both sets:

| Model | Dev | Held out | Signals missed | False alarms | Median time |
|---|---|---|---|---|---|
| Prompted instruct qwen3.5:4b + 15 examples | 32/40 (80%) | 19/28 (68%) | 2 | 2 | 5.9 s |
| Base, short prompt, no LoRA | 8/26 (31%)\* | — | — | — | 4.1 s |
| S1: LoRA, supervised | 32/40 (80%) | 17/28 (61%) | 3 | 1 | 4.0 s |
| S1 at step 500 (lowest validation loss) | 31/40 (78%) | — | 1 | 0 | 4.0 s |
| U1: LoRA, self-training only | 28/40 (70%) | 20/28 (71%) | 2 | 2 | 3.7 s |
| **SU: LoRA, supervised + self-training** | **34/40 (85%)** | **19/28 (68%)** | 2 | **0** | **3.9 s** |
| SU8: same data, LoRA on 8 layers | 31/40 (78%) | 20/28 (71%) | **1** | **0** | 4.1 s |

\* Without fine-tuning, the base model's JSON often failed to parse, so only 26 items produced a reading.

**Takeaways**

- Fine-tuning works: 31% → about 80%, matching the prompted instruct model, with no false alarms for SU, and about 35% faster per message because the few-shot prompt is gone.
- Self-training with no human labels (U1) reaches 70–71%. Keeping only unanimous pseudo-labels is a cheap way to get training data that's 87% correct.
- On 28 held-out items, one item is 3.6 points, so the differences between S, U, SU and SU8 are within noise. A larger held-out set is the next step before claiming a winner.
- The held-out set has now been used once for this comparison. The next round needs fresh test data.

## Follow-up: 30 more minutes on the weakest readings

36 new messages for *just being polite*, *joking*, *a polite no* and *not happy* were added to the pool (batch `weak1`, checked against the evaluation sets). Starting from the SU adapter, training continued for one pass over those items (each twice) mixed with 150 earlier items, at learning rate 5e-5. That took 14 minutes.

| Model | Dev | Held out | Signals missed | False alarms |
|---|---|---|---|---|
| SU (before) | 34/40 (85%) | 19/28 (68%) | 2 | 0 |
| SU2 (after) | 31/40 (78%) | 21/28 (75%) | 1 | 1 |

*Not happy* improved (held out 1/4 → 3/4, dev 2/3 → 3/3), but *a polite no* slipped on dev (8/9 → 5/9) and validation loss rose from 0.563 to 0.599. Overall it's a trade-off within noise, not a gain. The held-out set has now been used to compare several models, so it no longer counts as unseen: the next round needs fresh test data and, above all, more real training messages.

## Fresh held-out set and export to Ollama (2026-10-09)

The two LoRA arms were merged into the original bf16 weights ([`merge_lora.py`](merge_lora.py)) and imported into Ollama as 4-bit models ([`ollama/`](ollama/README.md)). On the development set, the Ollama export of SU scored 32/40 (MLX: 34/40), probably because of re-quantizing after merging.

Then a **fresh held-out set** of 40 messages ([`eval/crosscultural.holdout2.jsonl`](../eval/crosscultural.holdout2.jsonl)) was written after all tuning, checked against everything seen before, and run once per model:

| Model | Reading | Signals caught | False alarms | Median time |
|---|---|---|---|---|
| **Prompted instruct qwen3.5:4b + 15 examples** | **31/39 (79%)** | **6/8** | 0/10 | 6.3 s |
| SU, fine-tuned, Ollama q4_K_M | 24/39 (62%) | 4/8 | 0/10 | 4.5 s |
| SU2, fine-tuned, Ollama q4_K_M | 25/38 (66%) | 5/8 | 1/10 | 4.7 s |

**The fine-tuned models don't generalize as well.** On the development and first held-out sets they looked level with the prompted model, but both of those had been looked at while tuning. On genuinely new messages the prompted model is 13–17 points better and catches more signals. The fine-tuned models are about 30% faster. The app therefore keeps the prompted model as the default and offers the fine-tuned one only as an experimental Fast mode.

All three models missed one hopelessness message ("tired of everything… never going to get better"), and the fine-tuned ones missed a "pay our new bank" scam. Keyword patterns for both were added to the safety nets *after* seeing these items, so those two items no longer count as unseen for the keyword nets.

## Tuning the prompt instead (2026-10-09)

Since the fine-tuned models didn't generalize, the effort went into the prompt the app actually uses. The 324 labelled pool messages became a prompt-tuning set ([`pool_eval.jsonl`](pool_eval.jsonl)), large enough to show which readings get confused with which. The baseline mislabelled most errors as *means what it says*: 19 of 30 *just being polite*, 12 of 51 *a polite no*. The cause was a blunt "don't over-interpret" rule added earlier.

| Prompt | Pool (324) | Dev (40) | Held out v1 (28) | **Fresh held out v2 (39)** | Pool signals caught |
|---|---|---|---|---|---|
| v2 (before) | 67% | 80% | 68% | 79% | 70% |
| v3: ordered decision checklist instead of the blunt rule | 74% | 85% | — | — | 78% |
| v4: v3 + sharper joking/sarcasm/interest rules + 2 examples | 75% | 90% | — | — | 71% (missed 2 money requests) |
| **v5: v3 + sharper joking/sarcasm rules only (shipped)** | **75%** | **85%** | **79%** | **82%** | 77% |

v4 was dropped because it caught fewer money and account requests. v5 missed one ("reply with your password"), which it still labelled a red flag. The app now shows the scam card for any red-flag reading, and the keyword net covers password requests.

On the fresh held-out set, v5 is one item better than v2 (82% vs 79%). Most of the large pool gain is real for the confusions it targets (polite filler 8 → 20 of 30, joking 17 → 23 of 33), but part of it is the model learning the pool's labelling conventions, which come from the same author as the prompt.

## Pitfalls hit along the way

1. **MLX and Anaconda's MPI.** MLX found Anaconda's MPICH, decided it wasn't Open MPI, and aborted. [`mlx_run.py`](mlx_run.py) points `MLX_MPI_LIBNAME` at a missing library and uses the ring backend.
2. **Training Gated DeltaNet is a per-token loop.** Qwen3.5's linear-attention layers use a Metal kernel for inference but fall back to a Python loop over the sequence in training (the kernel has no VJP). Step time scales with the number of trained GDN layers: 0.073 / 0.139 / 0.195 steps per second at 16 / 8 / 5 LoRA layers. Letting frozen layers use the kernel is numerically identical but only about 5% faster. Reported as [ml-explore/mlx-lm#1956](https://github.com/ml-explore/mlx-lm/issues/1956).
3. **The server ignored the adapter.** mlx-lm 0.31.3's server looked up `--adapter-path` with the already-resolved model path, so every first-round "fine-tuned" evaluation actually measured the base model (identical outputs across arms gave it away). This was fixed upstream in mlx-lm 0.32.0 (PR #1249), and patched in `mlx_run.py` for 0.31.3.
4. **The model didn't stop.** The base tokenizer's end token is `<|endoftext|>`, but chat-format training teaches `<|im_end|>`, so generations ran to the token limit. The server now adds `<|im_end|>` as a stop token.
5. **Unescaped quotes in JSON.** Models quoting English phrases (`使用"Let me check"是…`) broke about a third of the outputs. The app's parser now repairs them.
6. **Memory.** Training while Ollama was generating labels used up 24 GB of memory, and the Mac froze and rebooted. GPU jobs now run strictly one at a time, with an MLX memory cap.

## Reproduce

```bash
python3 train/gen_labels.py S && python3 train/gen_labels.py U   # needs Ollama with qwen3.5:4b
python3 train/build_dataset.py S && python3 train/build_dataset.py U
zsh train/run_all.sh   # labels, four LoRA arms, dev and held-out evaluations, in order
python3 train/report.py
```

The 4-bit base model is created with `~/kev/.venv/bin/python train/mlx_run.py convert --hf-path <Qwen3.5-4B-Base snapshot> --mlx-path train/models/qwen35-4b-base-q4 -q`.
