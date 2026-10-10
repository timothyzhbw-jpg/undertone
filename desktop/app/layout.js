// 把 OCR 的行按位置拼成消息。单独成文件，方便不启动 Electron 也能测。
'use strict';

// eslint-disable-next-line no-var
var TIME_LINE = /^(?:(?:today|yesterday|mon|tue|wed|thu|fri|sat|sun)[a-z]*,?\s*)?(?:[a-z]{3,9}\.?\s+\d{1,2},?\s*(?:\d{4})?\s*)?(?:\d{1,2}[:.]\d{2}\s*(?:[ap]\.?m\.?)?)?$|^(?:delivered|seen|read|sent|edited)\b/i;

/** 有逐词信息时，去掉行首行尾置信度很低的「词」：头像、气泡边缘常被认成「BH」「\\」「)」。 */
function cleanLine(l) {
  if (!l.words || !l.words.length) return l;
  const words = [...l.words];
  while (words.length && words[0].confidence < 50) words.shift();
  while (words.length && words[words.length - 1].confidence < 50) words.pop();
  if (!words.length) return { ...l, text: '' };
  return { ...l, text: words.map(w => w.text).join(' '), x0: words[0].x0, x1: words[words.length - 1].x1,
    confidence: words.reduce((sum, w) => sum + w.confidence, 0) / words.length };
}

/**
 * lines: [{ text, confidence, x0, y0, x1, y1, words? }]（像素），width: 图片宽度。
 * 返回 [{ speaker: 'them' | 'me', text }]，从上到下。
 */
function layout(lines, width) {
  const kept = lines
    .map(cleanLine)
    .filter(l => l.text && l.confidence >= 45 && /[\p{L}\p{N}]/u.test(l.text))
    .sort((a, b) => a.y0 - b.y0);
  const heights = kept.map(l => l.y1 - l.y0).sort((a, b) => a - b);
  const lineHeight = heights.length ? heights[Math.floor(heights.length / 2)] : 20;

  const sided = kept.map(l => {
    const left = l.x0 / width;
    const right = (width - l.x1) / width;
    const span = (l.x1 - l.x0) / width;
    // 居中的短行：时间分隔、「已读」之类
    if (Math.abs(left - right) < 0.08 && span < 0.55 && (TIME_LINE.test(l.text) || l.text.length <= 24)) return { ...l, side: 'system' };
    if (TIME_LINE.test(l.text) && span < 0.3) return { ...l, side: 'system' };
    return { ...l, side: left <= right ? 'them' : 'me' };
  });

  const messages = [];
  let current = null;
  for (const l of sided) {
    if (l.side === 'system') { current = null; continue; }
    const sameBubble = current && current.side === l.side
      && l.y0 - current.y1 < lineHeight * 0.9
      && (l.side === 'them' ? Math.abs(l.x0 - current.x0) < width * 0.06 : Math.abs(l.x1 - current.x1) < width * 0.06);
    if (sameBubble) {
      current.text += ' ' + l.text;
      current.y1 = l.y1;
    } else {
      current = { side: l.side, text: l.text, x0: l.x0, x1: l.x1, y1: l.y1 };
      messages.push(current);
    }
  }
  return messages.map(m => {
    const text = m.text.replace(/\s+/g, ' ').trim();
    // 语音气泡只剩时长（「6"」「0:06」）：写成和 Mac 版一样的占位，提示词会附上说明
    const voice = text.match(/^[)》»\s]*(\d{1,3})\s*["″”'’]$/) || text.match(/^[)》»\s]*0?:(\d{2})$/);
    return { speaker: m.side, text: voice ? `[voice ${Number(voice[1])}s]` : text };
  });
}

/** OCR 每次读出来会有细小差别（标点、空格）：比较时只看字母和数字。 */
const key = text => text.toLowerCase().replace(/[^\p{L}\p{N}]/gu, '');

function similarity(a, b) {
  a = key(a); b = key(b);
  if (!a || !b) return 0;
  if (a === b) return 1;
  const dp = Array.from({ length: b.length + 1 }, (_, i) => i);
  for (let i = 1; i <= a.length; i++) {
    let prev = dp[0]; dp[0] = i;
    for (let j = 1; j <= b.length; j++) {
      const tmp = dp[j];
      dp[j] = Math.min(dp[j] + 1, dp[j - 1] + 1, prev + (a[i - 1] === b[j - 1] ? 0 : 1));
      prev = tmp;
    }
  }
  return 1 - dp[b.length] / Math.max(a.length, b.length);
}

// Node（主进程、测试）用 module.exports；界面里作为普通脚本加载，挂到 window 上
if (typeof module !== 'undefined') module.exports = { layout, similarity, key, cleanLine };
else window.undertoneLayout = { layout, similarity, key, cleanLine };
