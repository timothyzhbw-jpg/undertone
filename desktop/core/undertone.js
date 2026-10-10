// Undertone 的分析逻辑（桌面版）：和 Mac 版 Swift 代码（Sources/UndertoneCore）一一对应，
// 提示词直接读仓库里的 presets/，词表和关键词安全网从 Swift 源码抽出来（tools/extract_core.py → swift-data.json）。
// 这里不碰界面、截屏和 OCR，在 Node 里就能单独测试。
'use strict';

const fs = require('fs');
const path = require('path');
const data = require('./swift-data.json');

// MARK: - 语言

/** 解释用的语言（ExplanationLanguage）。 */
const EXPLANATION_LANGUAGES = [
  ['zh', '中文'], ['en', 'English'], ['es', 'Español'], ['fr', 'Français'], ['pt', 'Português'], ['de', 'Deutsch'],
  ['ru', 'Русский'], ['ar', 'العربية'], ['hi', 'हिन्दी'], ['id', 'Bahasa Indonesia'], ['ja', '日本語'], ['ko', '한국어'], ['vi', 'Tiếng Việt'],
];

// MARK: - 词表（Vocabulary）

const V = data.vocabulary;

function normalize(text) {
  return text.toLowerCase().replace(/_/g, ' ').replace(/-/g, ' ')
    .replace(/^[\s\p{P}]+|[\s\p{P}]+$/gu, '');
}

/** 把模型（或用户）给的任意写法认成中文规范值：先找完全一致的，再找包含的。认不出返回 null。 */
function canonical(raw, terms) {
  if (typeof raw !== 'string') return null;
  raw = raw.trim();
  if (!raw) return null;
  const key = normalize(raw);
  const keys = t => [t.en, ...t.aliases].map(normalize);
  const exact = terms.find(t => t.zh === raw || keys(t).includes(key));
  if (exact) return exact.zh;
  const loose = terms.find(t => raw.includes(t.zh) || keys(t).some(k => key.includes(k)));
  return loose ? loose.zh : null;
}

/** 规范值在界面语言下的文字。 */
function display(value, terms, ui) {
  if (value == null) return '';
  if (ui !== 'en') return value;
  const term = terms.find(t => t.zh === value);
  return term ? term.label : value;
}

/** 写进英文提示词里的说法（小写的模型标签）。 */
function english(value, terms) {
  if (value == null) return null;
  const zh = canonical(value, terms) || value;
  const term = terms.find(t => t.zh === zh);
  return term ? term.en : value;
}

// MARK: - 提示词

/** presets/ 目录：打包后在 resources/presets，开发时是仓库根目录的 presets。 */
function presetsDir() {
  const candidates = [
    process.env.UNDERTONE_PRESETS,
    process.resourcesPath && path.join(process.resourcesPath, 'presets'),
    path.join(__dirname, '..', '..', 'presets'),
  ].filter(Boolean);
  return candidates.find(dir => fs.existsSync(path.join(dir, 'subtext.llm.en.json')));
}

/** 某种解释语言的提示词文件名；没有就退回英文，再退回中文（Presets.file）。 */
function presetFile(base, code, dir = presetsDir()) {
  const names = [code, 'en', 'zh'].map(c => `${base}.${c}.json`);
  return names.find(n => fs.existsSync(path.join(dir, n))) || names[names.length - 1];
}

function loadPrompt(file, dir = presetsDir()) {
  const raw = JSON.parse(fs.readFileSync(path.join(dir, file), 'utf8'));
  return {
    system: raw.system,
    mediaNote: raw.media_note || null,
    examples: raw.examples,
    language: raw.language || 'zh',
    contextLength: raw.context_length || null,
  };
}

// MARK: - 聊天记录渲染（ChatState）

/** message: { speaker: 'me' | 'them' | 'system', text, sender? } */
function line(message, language = 'en') {
  if (language !== 'en') {
    if (message.speaker === 'me') return `我：${message.text}`;
    if (message.speaker === 'them') return message.sender ? `对方（${message.sender}）：${message.text}` : `对方：${message.text}`;
    return `［${message.text}］`;
  }
  if (message.speaker === 'me') return `Me: ${message.text}`;
  if (message.speaker === 'them') return message.sender ? `Them (${message.sender}): ${message.text}` : `Them: ${message.text}`;
  return `[${message.text}]`;
}

function knownRelation(relationship) {
  const relation = canonical(relationship, V.relationships) || relationship;
  return relation && relation !== '不确定' ? relation : null;
}

function render(context, latest, { relationship = null, memory = null, language = 'en' } = {}) {
  const relation = knownRelation(relationship);
  let text = '';
  if (language === 'en') {
    if (relation) text += `Relationship: ${english(relation, V.relationships) || relation}\n`;
    if (memory) text += memory + '\n\n';
    text += 'Chat log (oldest first; "Me" is the user, "Them" is the other person):\n';
    text += context.map(m => line(m, 'en')).join('\n');
    text += '\n\nAnalyze only their latest message:\n' + line(latest, 'en');
    return text;
  }
  if (relation) text += `双方关系：${relation}\n`;
  if (memory) text += memory + '\n\n';
  text += '以下是微信聊天记录（按时间顺序，「我」是用户，「对方」是聊天对象）：\n';
  text += context.map(m => line(m, 'zh')).join('\n');
  text += '\n\n需要分析的是对方最新这条：\n' + line(latest, 'zh');
  return text;
}

// MARK: - 示例答案的编码（和 Swift 的 JSONEncoder 输出一致：斜杠转义成 \/，整数不带小数点）

const FLAG_KEYS = ['angry_at_me', 'perfunctory', 'needs_comfort', 'testing', 'cold_distance', 'conflict', 'manipulation', 'self_harm', 'asks_money'];
const SUBTEXT_KEYS = ['literal', 'why', 'real_meaning', 'reading', 'confidence', 'emotion', 'intensity', 'target', ...FLAG_KEYS,
  'best_response', 'suggested_reply', 'reply_zh', 'memory_note'];
const EMOTION_KEYS = ['literal', 'consistency', 'real_meaning', 'emotion', 'intensity', 'target', ...FLAG_KEYS,
  'best_response', 'suggested_reply', 'memory_note'];
const DRAFT_KEYS = ['lands_as', 'verdict', 'issues', 'rewrite', 'rewrite_zh'];

function encodeValue(value) {
  if (typeof value === 'string') return JSON.stringify(value).replace(/\//g, '\\/');
  if (typeof value === 'number') return Number.isInteger(value) ? String(value) : JSON.stringify(value);
  return JSON.stringify(value);
}

function encodeInOrder(answer) {
  const order = 'reading' in answer ? SUBTEXT_KEYS : EMOTION_KEYS;
  const keys = order.filter(k => k in answer).concat(Object.keys(answer).filter(k => !order.includes(k)).sort());
  return '{' + keys.map(k => `"${k}": ${encodeValue(answer[k])}`).join(', ') + '}';
}

function encodeDraft(answer) {
  return '{' + DRAFT_KEYS.filter(k => k in answer).map(k => `"${k}": ${encodeValue(answer[k])}`).join(', ') + '}';
}

const hasMedia = text => /\[[^[\]\s]{1,40}\]/u.test(text);

/** few-shot 示例在前，当前对话在最后（LLMAnalyzer.turns）。 */
function analyzerTurns(prompt, context, latest, options = {}) {
  const turns = [];
  for (const example of prompt.examples) {
    turns.push({ role: 'user', content: example.chat });
    turns.push({ role: 'assistant', content: encodeInOrder(example.answer) });
  }
  let content = render(context, latest, { ...options, language: prompt.language });
  if (prompt.mediaNote && [...context, latest].some(m => hasMedia(m.text))) content += '\n\n' + prompt.mediaNote;
  turns.push({ role: 'user', content });
  return turns;
}

function renderDraft(context, draft, relationship = null) {
  const relation = knownRelation(relationship);
  let text = '';
  if (relation) text += `Relationship: ${english(relation, V.relationships) || relation}\n`;
  text += 'Chat log (oldest first; "Me" is the user, "Them" is the other person):\n';
  text += context.map(m => line(m, 'en')).join('\n');
  text += '\n\nMy draft reply:\n' + draft;
  return text;
}

function draftTurns(prompt, context, draft, relationship = null) {
  const turns = [];
  for (const example of prompt.examples) {
    turns.push({ role: 'user', content: example.chat });
    turns.push({ role: 'assistant', content: encodeDraft(example.answer) });
  }
  turns.push({ role: 'user', content: renderDraft(context, draft, relationship) });
  return turns;
}

// MARK: - 解析模型输出（LLMAnalyzer.parseObject 和两种修复）

/** 字符串里没转义的英文引号：只有后面紧跟 JSON 结构时才当作结束，否则转义。 */
function escapeInnerQuotes(json) {
  const chars = Array.from(json);
  let out = '';
  let inString = false;
  const nextNonSpace = from => { let j = from; while (j < chars.length && /\s/.test(chars[j])) j++; return j < chars.length ? j : -1; };
  for (let i = 0; i < chars.length; i++) {
    const c = chars[i];
    if (inString && c === '\\' && i + 1 < chars.length) { out += c + chars[i + 1]; i++; continue; }
    if (c === '"') {
      if (!inString) inString = true;
      else {
        let closes = true;
        const j = nextNonSpace(i + 1);
        if (j >= 0) {
          if ('}]:'.includes(chars[j])) closes = true;
          else if (chars[j] === ',') { const k = nextNonSpace(j + 1); closes = k < 0 || '"}]'.includes(chars[k]); }
          else closes = false;
        }
        if (closes) inString = false; else out += '\\';
      }
    }
    out += c;
  }
  return out;
}

/** 中文弯引号当成了 JSON 引号；值以英文引文开头或结尾时，开头或结尾的引号写成了 \"。 */
function repairQuotes(json) {
  return json
    .replace(/([:[,{]\s*)[“”]/g, '$1"')
    .replace(/[“”](\s*[,}\]:])/g, '"$1')
    .replace(/("\s*:\s*)\\"/g, '$1"\\"')
    .replace(/\\"(\s*,\s*"[A-Za-z_]+"\s*:|\s*\}\s*$)/g, '"$1');
}

function parseObject(content) {
  const start = content.indexOf('{');
  const end = content.lastIndexOf('}');
  if (start < 0 || end < start) return null;
  const raw = content.slice(start, end + 1);
  for (const candidate of [raw, repairQuotes(raw), escapeInnerQuotes(repairQuotes(raw))]) {
    try {
      const object = JSON.parse(candidate);
      if (object && typeof object === 'object' && !Array.isArray(object)) return object;
    } catch { /* 试下一种 */ }
  }
  return null;
}

const nonEmpty = v => (typeof v === 'string' && v.trim() ? v : null);
function number(v) {
  if (typeof v === 'number') return v;
  if (typeof v === 'boolean') return v ? 1 : 0;
  if (typeof v === 'string' && v.trim() !== '' && !Number.isNaN(Number(v))) return Number(v);
  return null;
}
function probability(v) {
  if (typeof v === 'string') return ['true', 'yes', '是', '1'].includes(v.toLowerCase()) ? 1 : (Number(v) || 0);
  const n = number(v);
  if (n == null) return 0;
  return n > 1 ? Math.min(1, n / 100) : Math.max(0, n);
}

function canonicalConsistency(raw) {
  if (typeof raw !== 'string') return null;
  return ['反话', '撒娇', '没说完', '一致'].find(x => raw.includes(x)) || canonical(raw, V.consistency);
}

class AnalyzerError extends Error {}

function reportFrom(content, message, engine, latencyMs) {
  const json = parseObject(content);
  if (!json) throw new AnalyzerError(`The analysis engine returned something unreadable: ${content.slice(0, 200)}`);
  const flags = {};
  for (const f of data.flags) flags[f.key] = probability(json[f.key]);
  const consistency = canonicalConsistency(json.consistency);
  const reading = canonical(json.reading, V.readings);
  if (consistency === '反话' || reading === '反话') flags.sarcasm = 1;
  const pick = (key, terms) => canonical(json[key], terms) || (typeof json[key] === 'string' ? json[key] : null);
  const confidence = number(json.confidence);
  return {
    message,
    emotion: pick('emotion', V.emotions) || '未知',
    intensity: Math.min(3, Math.max(0, number(json.intensity) || 0)),
    flags,
    bestResponse: pick('best_response', V.responses),
    consistency,
    target: pick('target', V.targets),
    literal: typeof json.literal === 'string' ? json.literal : null,
    realMeaning: typeof json.real_meaning === 'string' ? json.real_meaning : null,
    suggestedReply: typeof json.suggested_reply === 'string' ? json.suggested_reply : null,
    memoryNote: nonEmpty(json.memory_note),
    reading,
    confidence: confidence == null ? null : Math.min(3, Math.max(1, confidence)),
    cultureNote: nonEmpty(json.why),
    replyGloss: nonEmpty(json.reply_zh),
    engine,
    latencyMs,
    date: new Date().toISOString(),
  };
}

function reviewFrom(content, draft, engine, latencyMs) {
  const json = parseObject(content);
  if (!json) throw new AnalyzerError(`The analysis engine returned something unreadable: ${content.slice(0, 200)}`);
  const squash = t => t.toLowerCase().replace(/[^\p{L}\p{N}]/gu, '');
  const rewrite = nonEmpty(json.rewrite);
  return {
    draft,
    landsAs: nonEmpty(json.lands_as),
    verdict: canonical(json.verdict, V.verdicts) || (typeof json.verdict === 'string' ? json.verdict : '未知'),
    issues: nonEmpty(json.issues),
    rewrite,
    rewriteGloss: nonEmpty(json.rewrite_zh),
    rewriteDiffers: !!rewrite && squash(rewrite) !== squash(draft),
    engine,
    latencyMs,
  };
}

// MARK: - 关键词安全网（SafetyNet / MoneyNet）

/** Swift 的 (?i:…) 和开头的 (?i) 换成整体忽略大小写：中文没有大小写，不受影响。 */
function compile(patterns) {
  const body = patterns.map(p => `(?:${p.replace(/^\(\?i\)/, '').replace(/\(\?i:/g, '(?:')})`).join('|');
  return new RegExp(body, 'iu');
}
const SAFETY = compile(data.nets.safety);
const MONEY = compile(data.nets.money);
const MONEY_WORDS = compile(data.nets.moneyWords);
const NET_PROBABILITY = data.nets.probability;

function safetyMatch(text) {
  for (const candidate of [text, text.replace(/\s+/g, '')]) {
    const m = candidate.match(SAFETY);
    if (m) return m[0];
  }
  return null;
}
const moneyMatches = text => MONEY.test(text);
const mentionsMoney = text => MONEY_WORDS.test(text);

/** 两道关键词网（顺序和 Mac 版一样：先自伤，再钱）。 */
function applyNets(report) {
  const flags = { ...report.flags };
  const text = report.message.text;
  if (safetyMatch(text)) flags.self_harm = Math.max(flags.self_harm || 0, NET_PROBABILITY);
  if (moneyMatches(text)) flags.asks_money = Math.max(flags.asks_money || 0, NET_PROBABILITY);
  else if ((flags.asks_money || 0) > 0 && !mentionsMoney(text)) flags.asks_money = 0;
  return { ...report, flags };
}

function activeFlags(report, threshold = 0.5) {
  return data.flags.filter(f => (report.flags[f.key] || 0) >= threshold).map(f => f.key);
}

// MARK: - 粘贴的聊天记录（ChatTranscript）

const MY_NAMES = new Set(['我', '自己', '本人', 'me', 'i', 'you', 'myself']);
const RX = {
  header: /^(\S{1,20}?)\s+(?:\d{4}[-年]\d{1,2}[-月]\d{1,2}日?\s+)?(?:上午|下午|凌晨|晚上)?\s*\d{1,2}:\d{2}(?::\d{2})?$/u,
  englishHeader: /^((?:\p{Lu}[\p{L}'’.\-]*)(?:\s\p{Lu}[\p{L}'’.\-]*){0,2})\s*(?:,|—|–|-)?\s*\[?(?:(?:Today|Yesterday)(?:\s+at)?\s+|\d{1,2}\/\d{1,2}\/\d{2,4},?\s+)?\d{1,2}:\d{2}(?::\d{2})?\s?(?:[AaPp]\.?[Mm]\.?)?\]?$/u,
  leadingStamp: /^\[?\d{1,4}[/.\-]\d{1,2}[/.\-]\d{1,4},?\s+\d{1,2}:\d{2}(?::\d{2})?\s?(?:[AaPp]\.?[Mm]\.?)?\]?\s*(?:-\s+)?/u,
  englishTimeOnly: /^(?:(?:(?:Today|Yesterday|Mon(?:day)?|Tue(?:s|sday)?|Wed(?:nesday)?|Thu(?:rs|rsday)?|Fri(?:day)?|Sat(?:urday)?|Sun(?:day)?),?\s*)?(?:(?:Jan(?:uary)?|Feb(?:ruary)?|Mar(?:ch)?|Apr(?:il)?|May|June?|July?|Aug(?:ust)?|Sep(?:t|tember)?|Oct(?:ober)?|Nov(?:ember)?|Dec(?:ember)?)\.?\s+\d{1,2}(?:,\s*\d{4})?,?\s*)?(?:\d{1,2}\/\d{1,2}\/\d{2,4},?\s*)?(?:(?:at\s+)?\d{1,2}:\d{2}(?::\d{2})?\s?(?:[ap]\.?m\.?)?)?|(?:Delivered|Seen|Read|Sent)(?:\s+(?:at\s+)?\d{1,2}:\d{2}\s?(?:[ap]m)?)?)$/iu,
  prefixed: /^([^：:/\\]{1,20})(?<![0-9])[：:]\s*(.+)$/u,
  timeOnly: /^(?:昨天|今天|前天|星期[一二三四五六日天]|周[一二三四五六日天]|(?:\d{4}年)?\d{1,2}月\d{1,2}日)?\s*(?:上午|下午|凌晨|晚上)?\s*(?:\d{1,2}:\d{2}(?::\d{2})?)?$/u,
};

function parseTranscript(text, myNames = MY_NAMES) {
  const isMe = name => myNames.has(name) || myNames.has(name.toLowerCase());
  const collected = [];
  let pendingName = null;
  for (let raw of text.split(/\r?\n|\r/)) {
    let l = raw.trim().replace(RX.leadingStamp, '');
    if (!l) continue;
    if (RX.timeOnly.test(l) || RX.englishTimeOnly.test(l)) continue;
    const header = l.match(RX.header) || l.match(RX.englishHeader);
    if (header) { pendingName = header[1].trim(); continue; }
    const prefixed = l.match(RX.prefixed);
    if (prefixed && !prefixed[2].startsWith('//')) {
      collected.push({ name: prefixed[1].trim(), text: prefixed[2].trim() });
      pendingName = null;
      continue;
    }
    if (pendingName) { collected.push({ name: pendingName, text: l }); pendingName = null; }
    else if (collected.length) collected[collected.length - 1].text += '\n' + l;
    else collected.push({ name: null, text: l });
  }
  const counts = new Map();
  for (const item of collected) if (item.name && !isMe(item.name)) counts.set(item.name, (counts.get(item.name) || 0) + 1);
  const names = [...counts.entries()].sort((a, b) => b[1] - a[1] || (a[0] < b[0] ? -1 : 1)).map(e => e[0]);
  const messages = collected.map(item => ({
    speaker: item.name && isMe(item.name) ? 'me' : 'them',
    text: item.text,
    sender: item.name && !isMe(item.name) ? item.name : null,
  }));
  return { messages, names };
}

const PLACEHOLDER_NAME = 'Them';

/** 截图认出来的消息 → 粘贴框里的文字（ScreenshotTranscript.make）。 */
function screenshotTranscript(messages, ocrText) {
  const theirs = messages.filter(m => m.speaker === 'them');
  if (!theirs.length || !messages.some(m => m.speaker === 'me')) {
    const parts = theirs.length ? theirs.map(m => m.text) : ocrText;
    return parts.map(p => p.replace(/\n/g, ' ').trim()).filter(Boolean).join(' ');
  }
  const counts = new Map();
  for (const m of theirs) if (m.sender) counts.set(m.sender, (counts.get(m.sender) || 0) + 1);
  const usual = [...counts.entries()].sort((a, b) => b[1] - a[1])[0]?.[0] || PLACEHOLDER_NAME;
  return messages.filter(m => m.speaker !== 'system')
    .map(m => (m.speaker === 'me' ? `Me: ${m.text.replace(/\n/g, ' ')}` : `${m.sender || usual}: ${m.text.replace(/\n/g, ' ')}`))
    .join('\n');
}

// MARK: - 本地模型（Ollama）

const DEFAULT_CONTEXT = 6144;
const KEEP_ALIVE = '30m';

async function ollamaChat({ baseURL = 'http://127.0.0.1:11434', model = 'qwen3.5:4b', system, turns, contextLength, signal }) {
  const body = {
    model, stream: false, think: false, format: 'json', keep_alive: KEEP_ALIVE,
    options: { temperature: 0.2, num_ctx: Math.max(contextLength || 0, DEFAULT_CONTEXT) },
    messages: [{ role: 'system', content: system }, ...turns],
  };
  let response;
  try {
    response = await fetch(new URL('api/chat', baseURL.endsWith('/') ? baseURL : baseURL + '/'), {
      method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body), signal,
    });
  } catch {
    throw new AnalyzerError(`Can't reach Ollama at ${baseURL}. Install it from ollama.com, then run: ollama pull ${model}`);
  }
  const json = await response.json().catch(() => ({}));
  if (!response.ok) {
    if (response.status === 404) throw new AnalyzerError(`Ollama doesn't have ${model} yet. Run: ollama pull ${model}`);
    throw new AnalyzerError(`Ollama returned an error (HTTP ${response.status}): ${json.error || ''}`);
  }
  if (json.done_reason === 'length') throw new AnalyzerError("The local model's output was cut off (context too short)");
  const content = json.message && json.message.content;
  if (typeof content !== 'string') throw new AnalyzerError("Ollama's reply has no message.content");
  return content;
}

/** 读一条消息的话外音：提示词按解释语言挑，结果过两道关键词网。 */
async function analyze({ context, latest, explanation = 'en', relationship = null, memory = null, ollama = {}, dir = presetsDir() }) {
  const prompt = loadPrompt(presetFile('subtext.llm', explanation, dir), dir);
  const start = Date.now();
  const content = await ollamaChat({ ...ollama, system: prompt.system, turns: analyzerTurns(prompt, context, latest, { relationship, memory }),
    contextLength: prompt.contextLength });
  const engine = `Local model · ${ollama.model || 'qwen3.5:4b'}`;
  return applyNets(reportFrom(content, latest, engine, Date.now() - start));
}

/** 「发之前看看」。 */
async function checkDraft({ context, draft, explanation = 'en', relationship = null, ollama = {}, dir = presetsDir() }) {
  const prompt = loadPrompt(presetFile('draft.llm', explanation, dir), dir);
  const start = Date.now();
  const content = await ollamaChat({ ...ollama, system: prompt.system, turns: draftTurns(prompt, context, draft, relationship),
    contextLength: prompt.contextLength });
  return reviewFrom(content, draft, `Local model · ${ollama.model || 'qwen3.5:4b'}`, Date.now() - start);
}

module.exports = {
  EXPLANATION_LANGUAGES, vocabulary: V, flags: data.flags, canonical, display, english, normalize,
  presetsDir, presetFile, loadPrompt, line, render, renderDraft, encodeInOrder, encodeDraft, analyzerTurns, draftTurns,
  escapeInnerQuotes, repairQuotes, parseObject, reportFrom, reviewFrom, AnalyzerError,
  safetyMatch, moneyMatches, mentionsMoney, applyNets, activeFlags, NET_PROBABILITY,
  parseTranscript, screenshotTranscript, PLACEHOLDER_NAME, ollamaChat, analyze, checkDraft,
};
