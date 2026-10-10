#!/usr/bin/env python3
"""检查评测结果里的解释是不是真的用了要求的语言（小模型有时会退回英文）。

用法：python3 scripts/check_language.py 结果.jsonl es
按文字判断：日文看假名，韩文看谚文，中文看汉字，越南文看越南文特有的字母，
俄文、阿拉伯文、印地文看字母表，西、法、葡、德、印尼、英看常用虚词哪种最多。只看解释字段（理由、真实意思；「发之前看看」看感觉和问题）。
"""
import json
import re
import sys

STOPWORDS = {
    "en": "the a an is are and to of that it this they you be not for with on as but what so if their",
    "es": "el la los las es son y de que no un una para por con se lo su como pero más muy",
    "fr": "le la les est sont et de que ne pas un une pour par avec se ce il ils vous mais plus très",
    "pt": "o a os as é são e de que não um uma para por com se isso eles você mas mais muito",
    "de": "der die das ist sind und zu von dass nicht ein eine für mit sie es aber auch sehr",
    "id": "yang dan di ke dari ini itu untuk dengan tidak ada akan sudah mereka kamu anda saya atau juga bisa",
}
# 只算越南文独有的字母：â ê ô 法文、葡文也用，不能算
VIETNAMESE = set("ăđơưạảấầẩẫậắằẳẵặẹẻẽếềểễệỉịọỏốồổỗộớờởỡợụủứừửữựỳỵỷỹ")
FIELDS = ["cultureNote", "realMeaning", "landsAs", "issues"]


def language_of(text):
    if re.search(r"[぀-ヿ]", text):
        return "ja"
    if re.search(r"[Ѐ-ӿ]", text):
        return "ru"
    if re.search(r"[؀-ۿ]", text):
        return "ar"
    if re.search(r"[ऀ-ॿ]", text):
        return "hi"
    if re.search(r"[가-힯]", text):
        return "ko"
    if re.search(r"[一-鿿]", text):
        return "zh"
    if sum(ch in VIETNAMESE for ch in text.lower()) >= 2:
        return "vi"
    words = re.findall(r"[a-zà-ÿ]+", text.lower())
    counts = {lang: sum(w in set(sw.split()) for w in words) for lang, sw in STOPWORDS.items()}
    return max(counts, key=counts.get) if any(counts.values()) else "?"


def main(path, want):
    total = right = 0
    wrong = []
    for line in open(path):
        row = json.loads(line)
        text = " ".join(str(row.get(f) or "") for f in FIELDS).strip()
        if not text:
            continue
        total += 1
        got = language_of(text)
        if got == want:
            right += 1
        else:
            wrong.append((got, text[:90]))
    print(f"explained in {want}: {right}/{total}")
    for got, text in wrong[:5]:
        print(f"  [{got}] {text}")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
