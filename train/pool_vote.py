"""无监督标签的副产品：池子里每条都有金标，又有提示词模型的 3 次独立采样（temperature 0.8），
可以直接量出「采样一次」和「3 次投票」各自的准确率（288 条，比开发集大得多）。python3 pool_vote.py"""
import json
from collections import Counter
from pathlib import Path

HERE = Path(__file__).parent
pool = [json.loads(l) for l in (HERE / "pool.jsonl").open()]
labels = {json.loads(l)["index"]: json.loads(l) for l in (HERE / "labels_U.jsonl").open()}
single = [0, 0]; vote = [0, 0]; unanimous = [0, 0]; by_reading = {}
for i, item in enumerate(pool):
    rec = labels.get(i)
    if not rec: continue
    gold = item["gold"]["reading"]
    readings = [s.get("reading") for s in rec.get("samples", []) if isinstance(s, dict)]
    if not readings: continue
    for r in readings: single[0] += r == gold; single[1] += 1
    top, n = Counter(readings).most_common(1)[0]
    vote[0] += top == gold; vote[1] += 1
    if n == len(readings) == 3: unanimous[0] += top == gold; unanimous[1] += 1
    b = by_reading.setdefault(gold, [0, 0]); b[0] += top == gold; b[1] += 1
pct = lambda a: f"{a[0]}/{a[1]} ({100 * a[0] / a[1]:.0f}%)" if a[1] else "-"
print("采样一次：", pct(single))
print("3 次投票：", pct(vote))
print("3 次全一致的那些：", pct(unanimous), "← 无监督组用的就是这些")
print("按金标类型（投票）：", {k: pct(v) for k, v in sorted(by_reading.items(), key=lambda x: -x[1][1])})
