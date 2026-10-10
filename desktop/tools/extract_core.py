#!/usr/bin/env python3
"""从 Swift 源码里抽出词表和关键词安全网，写成 desktop/core/swift-data.json。
Mac 版（Swift）是唯一的来源：改了 Language.swift 或 SafetyNet.swift 以后重新运行，桌面版跟着更新。
用法：python3 desktop/tools/extract_core.py
"""
import json
import pathlib
import re

ROOT = pathlib.Path(__file__).resolve().parents[2]
CORE = ROOT / "Sources" / "UndertoneCore"


def swift_strings(text):
    """取出 #"…"# 和 "…" 字符串字面量（按出现顺序）。"""
    out = []
    for m in re.finditer(r'#"(.*?)"#|"((?:[^"\\]|\\.)*)"', text):
        if m.group(1) is not None:
            out.append(m.group(1))
        else:
            out.append(bytes(m.group(2), "utf-8").decode("unicode_escape").encode("latin-1").decode("utf-8"))
    return out


def terms(block):
    result = []
    for line in block.splitlines():
        m = re.search(r'Term\((.*)\),?\s*$', line.strip())
        if not m:
            continue
        body = m.group(1)
        label = re.search(r'label:\s*"([^"]*)"', body)
        aliases = re.search(r'aliases:\s*\[(.*?)\]', body)
        zh, en = re.findall(r'"([^"]*)"', body)[:2]
        result.append({"zh": zh, "en": en,
                       "label": label.group(1) if label else en[:1].upper() + en[1:],
                       "aliases": re.findall(r'"([^"]*)"', aliases.group(1)) if aliases else []})
    return result


def static_array(source, name):
    m = re.search(rf'static let {name} = \[(.*?)\n    \]', source, re.S)
    if not m:
        raise SystemExit(f"找不到 {name}")
    return m.group(1)


language = (CORE / "Language.swift").read_text()
safety = (CORE / "SafetyNet.swift").read_text()
report = (CORE / "EmotionReport.swift").read_text()

vocab = {name: terms(static_array(language, name))
         for name in ["emotions", "consistency", "targets", "responses", "relationships", "readings", "verdicts"]}

money_src = safety[safety.index("public enum MoneyNet"):]
nets = {
    "safety": swift_strings(static_array(safety, "patterns")),
    "money": swift_strings(static_array(money_src, "patterns")),
    "moneyWords": swift_strings(re.search(r'private static let money = try! NSRegularExpression\(pattern: \[(.*?)\]\.joined', money_src, re.S).group(1)),
    "probability": float(re.search(r'public static let probability = ([0-9.]+)', safety).group(1)),
}

flags = []
for m in re.finditer(r'case \.(\w+): language\.pick\("([^"]*)", "([^"]*)"\)', report):
    flags.append({"case": m.group(1), "zh": m.group(2), "en": m.group(3)})
raw = dict(re.findall(r'case (\w+) = "(\w+)"', report))
for f in flags:
    f["key"] = raw.get(f["case"], f["case"])

out = ROOT / "desktop" / "core" / "swift-data.json"
out.write_text(json.dumps({"vocabulary": vocab, "nets": nets, "flags": flags}, ensure_ascii=False, indent=1) + "\n")
print(f"{out.relative_to(ROOT)}: " + ", ".join(f"{k} {len(v)}" for k, v in vocab.items())
      + f"; safety {len(nets['safety'])}, money {len(nets['money'])}, flags {len(flags)}")
