// 桌面版的分析逻辑必须和 Mac 版完全一致：同一段聊天，发给模型的提示词一字不差；解析、关键词网、粘贴解析行为相同。
// fixtures/swift-prompt.*.json 由 Mac 版生成：.build/debug/Undertone --dump-prompt desktop/test/fixtures/chat.txt <语言> client
'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const u = require('../core/undertone');

const fixtures = path.join(__dirname, 'fixtures');
const repo = path.join(__dirname, '..', '..');

for (const code of ['en', 'zh', 'es', 'ja']) {
  test(`prompt matches the Mac app exactly (${code})`, () => {
    const swift = JSON.parse(fs.readFileSync(path.join(fixtures, `swift-prompt.${code}.json`), 'utf8'));
    const parsed = u.parseTranscript(fs.readFileSync(path.join(fixtures, 'chat.txt'), 'utf8'));
    const index = parsed.messages.map(m => m.speaker).lastIndexOf('them');
    const prompt = u.loadPrompt(u.presetFile('subtext.llm', code));
    assert.equal(prompt.system, swift.system);
    const turns = u.analyzerTurns(prompt, parsed.messages.slice(0, index).slice(-10), parsed.messages[index], { relationship: 'client' });
    assert.equal(turns.length, swift.turns.length);
    turns.forEach((t, i) => assert.deepEqual(t, swift.turns[i], `turn ${i}`));
    const draft = u.loadPrompt(u.presetFile('draft.llm', code));
    assert.equal(draft.system, swift.draftSystem);
    assert.deepEqual(u.draftTurns(draft, parsed.messages.slice(-10), 'Ok. Please tell me the reason.', 'client'), swift.draftTurns);
  });
}

test('every explanation language has prompts', () => {
  for (const [code] of u.EXPLANATION_LANGUAGES) {
    assert.equal(u.presetFile('subtext.llm', code), `subtext.llm.${code}.json`);
    assert.equal(u.presetFile('draft.llm', code), `draft.llm.${code}.json`);
  }
});

test('labels in any language map back to the canonical values', () => {
  assert.equal(u.canonical('negotiating', u.vocabulary.readings), '在压价');
  assert.equal(u.canonical('A polite no', u.vocabulary.readings), '委婉拒绝');
  assert.equal(u.canonical('red-flag', u.vocabulary.readings), '可疑');
  assert.equal(u.canonical('too blunt', u.vocabulary.verdicts), '太生硬');
  assert.equal(u.canonical('冷淡', u.vocabulary.readings), null, '情绪词不是话外音类型');
  assert.equal(u.display('在压价', u.vocabulary.readings, 'en'), 'Negotiating');
});

test('JSON repairs (same cases as the Swift tests)', () => {
  const curly = u.parseObject('{"emotion": "生气", "real_meaning": “想控制我”, "suggested_reply": "我们聊聊“信任”这件事吧”}');
  assert.equal(curly.real_meaning, '想控制我');
  assert.equal(curly.suggested_reply, '我们聊聊“信任”这件事吧');
  const inner = u.parseObject('{"why": "说"no, thanks"其实是拒绝", "reading": "委婉拒绝"}');
  assert.equal(inner.why, '说"no, thanks"其实是拒绝');
  const stray = u.parseObject('{"lands_as": \\"look\\" が二回使われています。", "verdict": "grammar issues", "issues": "\\"look look\\" は正しくありません。\\", "rewrite": "Can you take a look?"}');
  assert.equal(stray.lands_as, '"look" が二回使われています。');
  assert.equal(stray.issues, '"look look" は正しくありません。');
  assert.equal(u.parseObject('{"a": "say \\"hi\\", then go", "b": "x"}').a, 'say "hi", then go');
  assert.equal(u.parseObject('no json here'), null);
});

test('report parsing is tolerant and canonical', () => {
  const r = u.reportFrom('{"reading": "negotiating", "emotion": "calm", "asks_money": "true", "intensity": 5, "confidence": 0, "why": " "}',
    { speaker: 'them', text: 'too expensive' }, 't', 1);
  assert.equal(r.reading, '在压价');
  assert.equal(r.emotion, '平静');
  assert.equal(r.flags.asks_money, 1);
  assert.equal(r.intensity, 3);
  assert.equal(r.confidence, 1);
  assert.equal(r.cultureNote, null);
  assert.equal(u.reportFrom('{"reading": "sarcastic"}', { speaker: 'them', text: 'x' }, 't', 1).flags.sarcasm, 1);
});

test('safety nets', () => {
  assert.ok(u.safetyMatch('honestly everyone would be better off if I wasn\'t around'));
  assert.equal(u.safetyMatch("I'm dead 😂 this exam is going to kill me"), null);
  assert.ok(u.safetyMatch('不 想 活 了'));
  assert.ok(u.moneyMatches('Please note our bank account has changed. Kindly remit to the new account below.'));
  const report = (text, money) => ({ message: { speaker: 'them', text }, flags: { asks_money: money } });
  assert.equal(u.applyNets(report('Interesting. Let me run this by my team.', 0.9)).flags.asks_money, 0);
  assert.equal(u.applyNets(report('Please settle the invoice this week.', 0.9)).flags.asks_money, 0.9);
  assert.equal(u.applyNets(report('Our company switched banks, send the deposit to the account below.', 0)).flags.asks_money, u.NET_PROBABILITY);
});

test('every labelled must-raise money message mentions money', () => {
  let checked = 0;
  for (const file of ['eval/crosscultural.jsonl', 'eval/crosscultural.holdout.jsonl', 'eval/crosscultural.holdout2.jsonl', 'train/pool_eval.jsonl']) {
    for (const lineText of fs.readFileSync(path.join(repo, file), 'utf8').split('\n').filter(Boolean)) {
      const item = JSON.parse(lineText);
      if (!(item.expect && item.expect.flags || []).includes('asks_money')) continue;
      assert.ok(u.mentionsMoney(item.text), `${file}: ${item.text}`);
      checked++;
    }
  }
  assert.ok(checked > 20);
});

test('pasted transcripts', () => {
  const p = u.parseTranscript('[10/3/26, 3:05 PM] Amy: hey\nMe: hi\nAlice — Today at 3:05 PM\nare you free?\nsee https://example.com/x\nToday 3:06 PM\nJohn: ok');
  assert.deepEqual(p.messages.map(m => [m.speaker, m.sender, m.text]), [
    ['them', 'Amy', 'hey'], ['me', null, 'hi'], ['them', 'Alice', 'are you free?\nsee https://example.com/x'], ['them', 'John', 'ok']]);
  assert.deepEqual(p.names, ['Alice', 'Amy', 'John']);
  assert.equal(u.parseTranscript('just one line').messages[0].speaker, 'them');
});

test('screenshot transcripts', () => {
  const email = [{ speaker: 'them', text: 'Hi Lily,\nThanks for the quote.' }, { speaker: 'them', text: 'Best regards, Mark' }];
  assert.equal(u.screenshotTranscript(email, []), 'Hi Lily, Thanks for the quote. Best regards, Mark');
  const chat = [{ speaker: 'them', text: 'price?' }, { speaker: 'me', text: '$4' }, { speaker: 'them', text: 'too high' }];
  assert.equal(u.screenshotTranscript(chat, []), 'Them: price?\nMe: $4\nThem: too high');
});
