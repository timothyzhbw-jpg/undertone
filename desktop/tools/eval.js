#!/usr/bin/env node
// 桌面版的批量评测，输入输出和 Mac 版的 `Undertone --eval` 一样，可以直接用 scripts/score_eval.py 打分：
//   node desktop/tools/eval.js eval/crosscultural.holdout2.jsonl results.jsonl [解释语言，默认 en]
'use strict';
const fs = require('fs');
const u = require('../core/undertone');

async function main([input, output, explanation = 'en']) {
  const lines = fs.readFileSync(input, 'utf8').split('\n').filter(Boolean);
  const out = [];
  for (const [index, lineText] of lines.entries()) {
    const item = JSON.parse(lineText);
    const context = (item.context || '').split('\n').filter(Boolean).map(text => {
      for (const prefix of ['我：', 'Me:']) if (text.startsWith(prefix)) return { speaker: 'me', text: text.slice(prefix.length).trim() };
      const theirs = ['对方：', 'Them:'].find(p => text.startsWith(p));
      return { speaker: 'them', text: (theirs ? text.slice(theirs.length) : text).trim() };
    });
    try {
      if (item.draft) {
        const review = await u.checkDraft({ context, draft: item.draft, explanation, relationship: item.relationship });
        out.push(review);
        process.stderr.write(`${index + 1}/${lines.length} ${review.verdict}\n`);
      } else if (item.text) {
        const report = await u.analyze({ context, latest: { speaker: 'them', text: item.text }, explanation, relationship: item.relationship });
        out.push(report);
        process.stderr.write(`${index + 1}/${lines.length} ${report.reading || report.emotion}\n`);
      }
    } catch (error) {
      process.stderr.write(`${index + 1}/${lines.length} failed: ${error.message}\n`);
      out.push({ error: true });
    }
  }
  fs.writeFileSync(output, out.map(r => JSON.stringify(r)).join('\n') + '\n');
}

main(process.argv.slice(2));
