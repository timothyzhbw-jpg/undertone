"""汇总通宵实验：每组在开发集 / 留出集上的话外音准确率、安全信号、速度。python3 report.py"""
import json, re
from pathlib import Path

HERE = Path(__file__).parent
SETS = ["crosscultural", "crosscultural.holdout", "draft"]

def score(path):
    if not path.exists(): return None
    text = path.read_text()
    out = {}
    for key in ["reading", "verdict", "required flags", "forbidden flags"]:
        m = re.search(rf"^- {key}: (\d+)/(\d+)", text, re.M)
        if m: out[key] = (int(m[1]), int(m[2]))
    return out

def latency(path):
    if not path.exists(): return None
    vals = sorted(json.loads(l).get("latencyMs", 0) for l in path.open() if '"latencyMs"' in l)
    return vals[len(vals) // 2] / 1000 if vals else None

rows = []
for run in sorted((HERE / "runs").iterdir()):
    if not run.is_dir(): continue
    for s in SETS:
        sc = score(run / f"{s}.score.txt")
        if sc: rows.append((run.name, s, sc, latency(run / f"{s}.results.jsonl")))
# 提示词版本（Ollama + 15 条示例）在开发集上的数：第 2 轮调提示词时跑的，结果文件随 /tmp 在重启时丢了，这里记下分数
rows.insert(0, ("prompt", "crosscultural（第2轮）", {"reading": (32, 40), "required flags": (3, 3), "forbidden flags": (17, 18)}, 6.1))
fmt = lambda t: f"{t[0]}/{t[1]} ({100 * t[0] / t[1]:.0f}%)" if t else "-"
print(f"{'组':<8}{'评测集':<24}{'类型/判断':<16}{'该报的信号':<14}{'不该报的':<14}{'中位耗时'}")
for name, s, sc, lat in rows:
    main = sc.get("reading") or sc.get("verdict")
    print(f"{name:<8}{s:<24}{fmt(main):<16}{fmt(sc.get('required flags')):<14}{fmt(sc.get('forbidden flags')):<14}{(f'{lat:.1f}s' if lat else '-')}")
for run in sorted((HERE / "runs").glob("*/train.log")):
    vals = re.findall(r"Val loss ([\d.]+)", run.read_text())
    if vals: print(f"{run.parent.name} 验证 loss：{vals[0]} → {vals[-1]}（{len(vals)} 次）")
