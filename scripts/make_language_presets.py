#!/usr/bin/env python3
"""从英文提示词生成其他解释语言的提示词：subtext.llm.<代码>.json 和 draft.llm.<代码>.json。

规则部分保持英文（小模型最听得懂英文的指令），只把「用什么语言解释」改掉；示例答案里的解释换成
presets/languages/<代码>.json 里的译文。标签（reading、emotion…、verdict）仍是英文，解析时换回规范值。
改了英文提示词或示例以后重新运行：python3 scripts/make_language_presets.py
"""
import copy
import json
import pathlib
import sys

PRESETS = pathlib.Path(__file__).resolve().parent.parent / "presets"


def replace(text, old, new):
    if old not in text:
        sys.exit(f"英文提示词里找不到要替换的句子：{old[:60]}…")
    return text.replace(old, new)


def subtext_system(english, name, native):
    s = english
    s = replace(s, "Write every explanation in plain, simple English that an intermediate learner can follow: short sentences, common words, no idioms of your own.",
                f"The user's first language is {name}. Write literal, why, real_meaning, reply_zh and memory_note in plain, natural {name} ({native}): short sentences, common words. "
                f"Write suggested_reply in English. The labels for reading, emotion, target and best_response stay in English, exactly as listed below.")
    s = replace(s, "1. literal: say what the message literally says, in plain words, without interpreting it.",
                f"1. literal: translate the message into {name} word for word, without interpreting it.")
    s = replace(s, "2. why: one sentence on", f"2. why: one {name} sentence on")
    s = replace(s, "3. real_meaning: one sentence on", f"3. real_meaning: one {name} sentence on")
    s = replace(s, "reply_zh: in plain English, a short note on what this reply does.", f"reply_zh: what this reply means, in {name}.")
    s = replace(s, "write it down in one short English sentence", f"write it down in one short {name} sentence")
    return s


def draft_system(english, name, native):
    s = english
    s = replace(s, "Write your explanations in plain, simple English that an intermediate learner can follow.",
                f"The user's first language is {name}. Write lands_as, issues and rewrite_zh in plain, natural {name} ({native}). "
                f"The rewrite itself stays in English, and verdict is one of the English labels below.")
    s = replace(s, "1. lands_as: one sentence on", f"1. lands_as: one {name} sentence on")
    s = replace(s, "3. issues: one sentence pointing", f"3. issues: one {name} sentence pointing")
    s = replace(s, "5. rewrite_zh: in plain English, a short note on what the rewrite changes.", f"5. rewrite_zh: what the rewrite means, in {name}.")
    return s


def build(code):
    spec = json.loads((PRESETS / "languages" / f"{code}.json").read_text())
    name, native = spec["name"], spec["native"]

    subtext = json.loads((PRESETS / "subtext.llm.en.json").read_text())
    out = copy.deepcopy(subtext)
    out["id"] = f"subtext.llm.{code}"
    out["name"] = f"Cross-cultural: reading between the lines of English messages, explained in {name} (generative model)"
    out["system"] = subtext_system(subtext["system"], name, native)
    if len(spec["subtext"]) != len(out["examples"]):
        sys.exit(f"{code}: subtext 译文 {len(spec['subtext'])} 条，示例 {len(out['examples'])} 条")
    for example, (literal, why, real, reply, memory) in zip(out["examples"], spec["subtext"]):
        answer = example["answer"]
        if bool(memory) != bool(answer["memory_note"]):
            sys.exit(f"{code}: memory_note 有无和英文示例不一致：{example['chat'][-60:]}")
        answer.update(literal=literal, why=why, real_meaning=real, reply_zh=reply, memory_note=memory)

    draft = json.loads((PRESETS / "draft.llm.en.json").read_text())
    dout = copy.deepcopy(draft)
    dout["id"] = f"draft.llm.{code}"
    dout["name"] = f"Check before you send, explained in {name} (generative model)"
    dout["system"] = draft_system(draft["system"], name, native)
    if len(spec["draft"]) != len(dout["examples"]):
        sys.exit(f"{code}: draft 译文 {len(spec['draft'])} 条，示例 {len(dout['examples'])} 条")
    for example, (lands, issues, rewrite) in zip(dout["examples"], spec["draft"]):
        example["answer"].update(lands_as=lands, issues=issues, rewrite_zh=rewrite)

    for path, data in [(f"subtext.llm.{code}.json", out), (f"draft.llm.{code}.json", dout)]:
        (PRESETS / path).write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n")
    print(f"{code}: {name}")


if __name__ == "__main__":
    codes = sys.argv[1:] or sorted(p.stem for p in (PRESETS / "languages").glob("*.json"))
    for code in codes:
        build(code)
