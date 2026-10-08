"""给输入池生成训练标签。

  python3 gen_labels.py S   有监督：告诉模型金标（类型、信号、回应），让它写解释和回复；结果里的金标字段以金标为准
  python3 gen_labels.py U   无监督：不给任何金标，同一条采样 3 次（temperature 0.8），之后按多数一致取伪标签
可以中断后接着跑（按条目序号跳过已完成的）。只调用本机 Ollama。
"""
import json, sys, time, urllib.request
from pathlib import Path

HERE = Path(__file__).parent
PRESET = json.load((HERE.parent / "presets" / "subtext.llm.zh.json").open())
KEYS = ["literal", "why", "real_meaning", "reading", "confidence", "emotion", "intensity", "target",
        "angry_at_me", "perfunctory", "needs_comfort", "testing", "cold_distance", "conflict", "manipulation", "self_harm", "asks_money",
        "best_response", "suggested_reply", "reply_zh", "memory_note"]
FLAGS = KEYS[8:17]

def render(relationship, context, latest):
    """和 ChatState.render(language: .en) 一模一样。"""
    text = f"Relationship: {relationship}\n" if relationship else ""
    text += 'Chat log (oldest first; "Me" is the user, "Them" is the other person):\n'
    text += context
    text += "\n\nAnalyze only their latest message:\nThem: " + latest
    return text

def ordered(answer):
    return json.dumps({k: answer[k] for k in KEYS if k in answer}, ensure_ascii=False)

def chat(user, temperature):
    messages = [{"role": "system", "content": PRESET["system"]}]
    for e in PRESET["examples"]:
        messages += [{"role": "user", "content": e["chat"]}, {"role": "assistant", "content": ordered(e["answer"])}]
    messages.append({"role": "user", "content": user})
    body = {"model": "qwen3.5:4b", "stream": False, "think": False, "format": "json", "keep_alive": "30m",
            "options": {"temperature": temperature, "num_ctx": 8192}, "messages": messages}
    req = urllib.request.Request("http://127.0.0.1:11434/api/chat", data=json.dumps(body).encode(), headers={"Content-Type": "application/json"})
    r = json.load(urllib.request.urlopen(req, timeout=300))
    return r["message"]["content"]

def hint(gold):
    flags = "、".join(gold["flags"]) if gold["flags"] else "没有（全部为 false）"
    return (f"\n\n（参考答案：reading 是「{gold['reading']}」；必须为 true 的信号：{flags}；best_response 是「{gold['best_response']}」。"
            "请按这个答案写出完整的 JSON，why 和 real_meaning 要说清楚为什么是这个类型。）")

def main(mode, limit=None):
    pool = [json.loads(l) for l in (HERE / "pool.jsonl").open()]
    out_path = HERE / f"labels_{mode}.jsonl"
    done = {json.loads(l)["index"] for l in out_path.open()} if out_path.exists() else set()
    todo = [i for i in range(len(pool)) if i not in done][:limit]
    start = time.time()
    with out_path.open("a") as out:
        for n, i in enumerate(todo):
            item = pool[i]
            user = render(item["relationship"], item["context"], item["text"])
            record = {"index": i, "text": item["text"]}
            try:
                if mode == "S":
                    answer = json.loads(chat(user + hint(item["gold"]), 0.2))
                    answer["reading"] = item["gold"]["reading"]
                    answer["best_response"] = item["gold"]["best_response"]
                    for f in FLAGS: answer[f] = f in item["gold"]["flags"]
                    record["answer"] = answer
                else:
                    record["samples"] = []
                    for _ in range(3):
                        try: record["samples"].append(json.loads(chat(user, 0.8)))
                        except Exception as e: record["samples"].append({"error": str(e)})
            except Exception as e:
                record["error"] = str(e)
            out.write(json.dumps(record, ensure_ascii=False) + "\n"); out.flush()
            per = (time.time() - start) / (n + 1)
            print(f"{mode} {n + 1}/{len(todo)} #{i} {per:.1f}s/item", flush=True)

if __name__ == "__main__":
    main(sys.argv[1], int(sys.argv[2]) if len(sys.argv) > 2 else None)
