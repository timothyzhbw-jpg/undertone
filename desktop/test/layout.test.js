// 版面：OCR 的行 → 气泡。用的是真实截图里出现过的情况（头像被认成「BH」、语音气泡只剩时长、居中的时间）。
'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { layout, similarity } = require('../app/layout');

const word = (text, x0, x1, confidence = 96) => ({ text, x0, x1, confidence });
const line = (y0, words) => ({ text: words.map(w => w.text).join(' '), confidence: 90, x0: words[0].x0, x1: words[words.length - 1].x1, y0, y1: y0 + 26, words });

test('avatar noise is dropped and bubble lines are merged', () => {
  const lines = [
    line(54, [word('BH', 27, 90, 26), word('Interesting.', 149, 290), word('Let', 302, 340), word('me', 350, 380)]),
    line(84, [word('circle', 148, 220), word('back.', 226, 293)]),
    line(200, [word('Sure,', 620, 700), word('Friday.', 900, 1010)]),
  ];
  assert.deepEqual(layout(lines, 1040), [
    { speaker: 'them', text: 'Interesting. Let me circle back.' },
    { speaker: 'me', text: 'Sure, Friday.' },
  ]);
});

test('voice bubbles become a placeholder and centered time lines are skipped', () => {
  const lines = [
    { text: '6"', confidence: 90, x0: 150, x1: 200, y0: 10, y1: 36 },
    { text: 'Yesterday 9:05 PM', confidence: 95, x0: 420, x1: 620, y0: 80, y1: 106 },
    { text: 'Thanks, got it.', confidence: 95, x0: 150, x1: 400, y0: 140, y1: 166 },
  ];
  assert.deepEqual(layout(lines, 1040), [{ speaker: 'them', text: '[voice 6s]' }, { speaker: 'them', text: 'Thanks, got it.' }]);
});

test('low-confidence lines are ignored', () => {
  assert.deepEqual(layout([{ text: 'Woe', confidence: 36, x0: 31, x1: 103, y0: 190, y1: 262 }], 1040), []);
});

test('OCR jitter still counts as the same message', () => {
  assert.ok(similarity('Just following up on the revised quote, our team is waiting.', 'Just following up on the revised quote our team is waiting') > 0.95);
  assert.ok(similarity('Thanks, got it.', 'Please note our bank account has changed.') < 0.5);
});
