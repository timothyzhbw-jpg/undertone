"""训练输入池的工具：每条 = 关系 + 上文 + 对方最新一条 + 金标（话外音类型、必须报的信号、建议回应）。"""
import json, re
from pathlib import Path

HERE = Path(__file__).parent
POOL = HERE / "pool.jsonl"
READINGS = ["字面意思", "客套", "委婉拒绝", "还没决定", "在催你", "不满", "有兴趣", "在压价", "反话", "开玩笑", "可疑"]
RESPONSES = ["正常聊天", "解释澄清", "真诚道歉", "跟进推进", "给对方空间", "守住边界", "核实身份", "安慰共情", "用行动关心", "寻求帮助"]
FLAGS = ["angry_at_me", "perfunctory", "needs_comfort", "testing", "cold_distance", "conflict", "manipulation", "self_harm", "asks_money"]
REL = {"c": "client", "w": "coworker", "p": "professor", "s": "classmate", "f": "friend", "-": None}

def add_batch(batch_name, rows):
    """rows: (关系缩写, 上文（我说的话，可空）, 对方的话, 类型, 信号（空格分隔）, 回应)"""
    out = []
    for rel, me, them, reading, flags, response in rows:
        assert reading in READINGS, reading
        assert response in RESPONSES, response
        fl = flags.split() if flags else []
        for f in fl: assert f in FLAGS, f
        out.append({"batch": batch_name, "relationship": REL[rel], "context": f"Me: {me}" if me else "", "text": them,
                    "gold": {"reading": reading, "flags": fl, "best_response": response}})
    existing = [json.loads(l) for l in POOL.open()] if POOL.exists() else []
    existing = [e for e in existing if e["batch"] != batch_name] + out
    with POOL.open("w") as f:
        for e in existing: f.write(json.dumps(e, ensure_ascii=False) + "\n")
    print(batch_name, len(out), "→ pool", len(existing))

def words(s): return set(re.findall(r"[a-z']+", s.lower()))

def overlap_report(threshold=0.6):
    """池子里和评测集（开发集、留出集）太像的条目：词集合的 Jaccard 相似度超过阈值。"""
    evals = []
    for name in ["crosscultural.jsonl", "crosscultural.holdout.jsonl"]:
        evals += [json.loads(l)["text"] for l in (HERE.parent / "eval" / name).open()]
    prompt = json.load((HERE.parent / "presets" / "subtext.llm.zh.json").open())
    evals += [e["chat"].rsplit("Them: ", 1)[-1] for e in prompt["examples"]]
    bad = []
    for e in (json.loads(l) for l in POOL.open()):
        a = words(e["text"])
        for t in evals:
            b = words(t)
            if a and b and len(a & b) / len(a | b) >= threshold:
                bad.append((e["text"], t))
    return bad
