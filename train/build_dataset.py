"""把生成的标签整理成 mlx_lm.lora 的训练集（chat 格式，只在回答上算 loss）。

  python3 build_dataset.py S   → data_S/{train,valid}.jsonl
  python3 build_dataset.py U   → data_U/{train,valid}.jsonl（3 次采样里话外音类型至少 MIN_AGREE 次一致的才要）
两组用同一个按序号划分的验证集（每 10 条取 1 条），对比才公平。
"""
import json, sys
from collections import Counter
from pathlib import Path
from gen_labels import render, KEYS, FLAGS

HERE = Path(__file__).parent
READINGS = ["字面意思", "客套", "委婉拒绝", "还没决定", "在催你", "不满", "有兴趣", "在压价", "反话", "开玩笑", "可疑"]
EMOTIONS = ["开心", "平静", "亲昵", "难过", "委屈", "生气", "失望", "焦虑", "冷淡", "尴尬"]
TARGETS = ["我", "自己", "别人", "这件事"]
RESPONSES = ["正常聊天", "解释澄清", "真诚道歉", "跟进推进", "给对方空间", "守住边界", "核实身份", "安慰共情", "用行动关心", "寻求帮助"]
MIN_AGREE = 3

# 微调后的模型不再需要长提示和示例：只用这段简短的说明。必须和 presets/subtext.ft.zh.json 的 system 一字不差。
FT_SYSTEM = ("你是跨文化沟通顾问，帮中文母语的用户读懂英文消息的言外之意。只分析对方（Them）最新的一条，输出一个 JSON："
             "literal 直译成中文；why 英语母语者在这种场合这样说的习惯和原因；real_meaning 对方真正的意思；"
             "reading 从 " + "、".join(READINGS) + " 中选一个；confidence 1 到 3；emotion 从 " + "、".join(EMOTIONS) + " 中选一个；"
             "intensity 0 到 3；target 从 " + "、".join(TARGETS) + " 中选一个；" + "、".join(FLAGS) + " 是布尔值；"
             "best_response 从 " + "、".join(RESPONSES) + " 中选一个；suggested_reply 一句地道的英文回复，不编造用户没说过的事实；"
             "reply_zh 这句回复的中文意思；memory_note 值得记住的具体事情，没有就留空字符串。")

def valid_answer(a):
    return (isinstance(a, dict) and a.get("reading") in READINGS and a.get("emotion") in EMOTIONS and a.get("target") in TARGETS
            and a.get("best_response") in RESPONSES and all(isinstance(a.get(k), str) and a[k].strip() for k in ["literal", "why", "real_meaning", "suggested_reply", "reply_zh"]))

def clean(a):
    out = {}
    for k in KEYS:
        v = a.get(k)
        if k in FLAGS: v = bool(v) if not isinstance(v, str) else v.lower() == "true"
        elif k in ("confidence", "intensity"):
            try: v = int(round(float(v)))
            except Exception: v = 2 if k == "confidence" else 1
            v = max(1, min(3, v)) if k == "confidence" else max(0, min(3, v))
        elif k == "memory_note": v = v if isinstance(v, str) else ""
        out[k] = v
    return out

def main(mode):
    pool = [json.loads(l) for l in (HERE / "pool.jsonl").open()]
    labels = {json.loads(l)["index"]: json.loads(l) for l in (HERE / f"labels_{mode}.jsonl").open()}
    rows, dropped = {"train": [], "valid": []}, Counter()
    for i, item in enumerate(pool):
        rec = labels.get(i)
        if not rec: dropped["missing"] += 1; continue
        if mode == "S":
            answer = rec.get("answer")
        else:
            samples = [s for s in rec.get("samples", []) if valid_answer(s)]
            votes = Counter(s["reading"] for s in samples)
            if not votes or votes.most_common(1)[0][1] < MIN_AGREE: dropped["no consensus"] += 1; continue
            top = votes.most_common(1)[0][0]
            answer = next(s for s in samples if s["reading"] == top)
        if not valid_answer(answer): dropped["invalid"] += 1; continue
        user = render(item["relationship"], item["context"], item["text"])
        example = {"messages": [{"role": "system", "content": FT_SYSTEM}, {"role": "user", "content": user},
                                {"role": "assistant", "content": json.dumps(clean(answer), ensure_ascii=False)}]}
        rows["valid" if i % 10 == 0 else "train"].append(example)
    out = HERE / f"data_{mode}"
    out.mkdir(exist_ok=True)
    for split, items in rows.items():
        with (out / f"{split}.jsonl").open("w") as f:
            for r in items: f.write(json.dumps(r, ensure_ascii=False) + "\n")
    print(mode, {k: len(v) for k, v in rows.items()}, dict(dropped))

if __name__ == "__main__":
    main(sys.argv[1])
