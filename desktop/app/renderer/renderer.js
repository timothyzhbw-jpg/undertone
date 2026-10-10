// 面板界面：实时模式（看一个聊天窗口）、粘贴模式（文字或截图）、报告、「发之前看看」。
'use strict';

const api = window.undertone;
const layoutTools = window.undertoneLayout;
const $ = id => document.getElementById(id);

let S = null;               // 设置（含 vocabulary、flags、languages）
let ui = 'en';
const L = (zh, en) => (ui === 'zh' ? zh : en);

const state = {
  mode: 'paste',
  paused: false,
  analyzing: false,
  pending: null,            // 分析期间来的新消息只留最新一条
  reports: [],              // 最新在前
  shown: 0,
  error: null,
  liveMessages: [],         // 实时模式最近一次读出的消息（「发之前看看」的上下文）
  lastAnalyzed: null,
  status: '',
};

// MARK: - 词表

const RELATIONSHIPS = ['不确定', '客户', '同事', '老师', '同学', '朋友'];
const label = (value, table) => {
  if (!value) return '';
  if (ui !== 'en') return value;
  const term = S.vocabulary[table].find(t => t.zh === value);
  return term ? term.label : value;
};
const READING_COLOR = r => ({ 有兴趣: 'var(--reply)', 委婉拒绝: 'var(--warn)', 不满: 'var(--warn)', 在催你: 'var(--warn)', 反话: 'var(--warn)',
  可疑: 'var(--danger)', 在压价: 'var(--blue)', 还没决定: 'var(--blue)' }[r] || 'var(--neutral)');
const tint = (color, alpha) => `color-mix(in srgb, ${color} ${alpha}%, transparent)`;

// MARK: - 小工具

function el(tag, attrs = {}, ...children) {
  const node = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs)) {
    if (k === 'class') node.className = v;
    else if (k === 'style') node.style.cssText = v;
    else if (k.startsWith('on')) node.addEventListener(k.slice(2), v);
    else node.setAttribute(k, v);
  }
  for (const child of children.flat()) if (child != null && child !== false) node.append(child instanceof Node ? child : String(child));
  return node;
}
const time = iso => new Date(iso).toLocaleTimeString(ui === 'zh' ? 'zh-CN' : 'en-US', { hour: 'numeric', minute: '2-digit' });

// MARK: - 界面文字

function applyTexts() {
  document.documentElement.lang = ui;
  $('liveTab').textContent = L('实时看聊天', 'Live');
  $('pasteTab').textContent = L('手动粘贴', 'Paste');
  $('pauseButton').title = L('暂停', 'Pause');
  $('settingsButton').title = L('设置', 'Settings');
  $('pickerTitle').textContent = L('选要看的聊天窗口', 'Pick the chat window to watch');
  $('pickerHint').textContent = L('只读这个窗口里对方发来的英文消息，不会碰别的窗口，也不会替你发消息。',
    "Undertone only reads this window and never sends anything. Keep the chat visible on screen.");
  $('refreshWindows').textContent = L('刷新', 'Refresh');
  $('pasteTitle').textContent = L('粘贴聊天记录', 'Paste a chat');
  $('transcript').placeholder = 'John: Thanks for the quote. We\'ll review it internally and get back to you.';
  $('pasteHint').textContent = L('复制几条消息粘贴进来（「名字: 内容」，没名字的行算对方说的）；也可以粘贴或拖进一张聊天、邮件截图，在本机识别。',
    'Copy a few messages and paste them here ("Name: message"; lines without a name count as theirs). You can also paste or drop a screenshot of a chat or an email; it\'s read on this computer.');
  $('pasteImage').textContent = L('粘贴截图', 'Paste screenshot');
  $('clearPaste').textContent = L('清空', 'Clear');
  $('draftTitle').textContent = L('发之前看看', 'Check before you send');
  $('draftText').placeholder = L('输入你准备发的英文回复，看看对方读起来是什么感觉', "Type the reply you're about to send to see how it will come across");
  $('clearDraft').textContent = L('清空', 'Clear');
  $('checkDraft').textContent = L('帮我看看', 'Check it');
  $('recentTitle').textContent = L('最近', 'Recent');
  $('footer').textContent = L('只在本机分析，不上传聊天内容 · 结果仅供参考', 'Analyzed on this computer only, nothing uploaded · for reference only');
  $('settingsTitle').textContent = L('设置', 'Settings');
  $('uiLabel').textContent = L('界面语言', 'Interface');
  $('explainLabel').textContent = L('解释用的语言', 'Explain in');
  $('explainHint').textContent = L('建议的回复始终是英文。', 'Suggested replies are always in English.');
  $('modelLabel').textContent = L('本地模型', 'Local model');
  $('urlLabel').textContent = L('Ollama 地址', 'Ollama URL');
  $('topLabel').textContent = L('面板总在最前面', 'Keep the panel on top');
  $('liveSettingsTitle').textContent = L('实时模式', 'Live mode');
  $('cropTopLabel').textContent = L('去掉顶部 %（标题、联系人名）', 'Skip top % (title bar, contact name)');
  $('cropBottomLabel').textContent = L('去掉底部 %（输入框）', 'Skip bottom % (message box)');
  $('changeWindow').textContent = L('换一个窗口', 'Watch a different window');
  $('closeSettings').textContent = L('完成', 'Done');
  $('aboutText').textContent = `Undertone ${S.version} · github.com/timothyzhbw-jpg/undertone`;
  renderRelationships();
  updateButtons();
}

function renderRelationships() {
  const bar = $('relationships');
  bar.replaceChildren(...RELATIONSHIPS.map(r => el('button', {
    class: r === S.relationship ? 'on' : '', title: L('你和 TA 的关系，会影响对潜台词的判断', 'How you know them — the same words mean different things in different relationships'),
    onclick: async () => { S = { ...S, ...(await api.save({ relationship: r })) }; renderRelationships(); },
  }, label(r, 'relationships'))));
}

function setStatus() {
  const dot = $('statusDot');
  dot.className = 'dot';
  let text;
  if (state.analyzing) { dot.classList.add('busy'); text = L('正在分析…', 'Analyzing…'); }
  else if (state.error) { dot.classList.add('error'); text = L('出了点问题', 'Something went wrong'); }
  else if (state.mode === 'paste') { dot.classList.add('paste'); text = L('手动模式 · 不截屏', 'Manual mode · no screen capture'); }
  else if (state.paused) text = L('已暂停', 'Paused');
  else if (live.running) { dot.classList.add('on'); text = L(`正在看 · ${S.windowName || ''}`, `Watching · ${S.windowName || ''}`); }
  else text = L('还没选聊天窗口', 'No chat window yet');
  $('statusText').textContent = text;
}

function updateButtons() {
  $('liveTab').classList.toggle('on', state.mode === 'live');
  $('pasteTab').classList.toggle('on', state.mode === 'paste');
  $('pauseButton').classList.toggle('hidden', state.mode !== 'live' || !live.running && !state.paused);
  $('analyzePaste').textContent = state.analyzing ? L('分析中…', 'Analyzing…') : L('分析这段', 'Analyze');
  $('analyzePaste').disabled = state.analyzing;
  setStatus();
}

// MARK: - 报告

function render() {
  updateButtons();
  $('paste').classList.toggle('hidden', state.mode !== 'paste');
  $('windowPicker').classList.toggle('hidden', !(state.mode === 'live' && !live.running && !state.paused));
  const notice = $('notice');
  notice.classList.toggle('hidden', !state.error);
  if (state.error) {
    notice.replaceChildren(el('div', { class: 'card-title' }, L('这条消息没分析成功', "Couldn't analyze this message")),
      el('div', { class: 'card-text' }, state.error),
      /Ollama|ollama/.test(state.error) ? el('a', { onclick: () => api.open('https://ollama.com/download') }, L('去下载 Ollama', 'Download Ollama')) : null);
  }
  const report = state.reports[state.shown];
  $('empty').classList.toggle('hidden', !!report || state.mode === 'paste' && !state.analyzing);
  $('emptyTitle').textContent = state.analyzing ? L('正在读 TA 的消息…', 'Reading their message…') : L('等 TA 发来新消息', 'Waiting for their next message');
  $('emptyText').textContent = L('打开和外国客户、同事或老师的聊天窗口。对方发来英文消息，这里会告诉你 TA 真正的意思，以及怎么回。',
    'Open a chat with a client, coworker or professor. When they write in English, this explains what they really mean and how to reply.');
  const box = $('report');
  box.classList.toggle('hidden', !report);
  if (report) box.replaceChildren(...reportView(report));
  renderRecent();
}

function reportView(r) {
  const parts = [];
  parts.push(el('div', { class: 'said' },
    el('div', { class: 'said-head' }, el('span', {}, state.shown === 0 ? L('TA 刚刚说', 'They just said') : L('TA 之前说', 'They said earlier'),
      r.message.sender ? el('span', { class: 'sender' }, r.message.sender) : null), el('span', { class: 'time' }, time(r.date))),
    el('div', { class: 'bubble-row' }, el('div', { class: 'avatar' }), el('div', { class: 'bubble' }, r.message.text))));

  const active = new Set(r.active || []);
  const chips = [...active].filter(k => !['sarcasm', 'manipulation', 'self_harm', 'asks_money'].includes(k))
    .map(k => el('span', { class: 'flag' }, ui === 'zh' ? S.flags.find(f => f.key === k).zh : S.flags.find(f => f.key === k).en));
  if (chips.length) parts.push(el('div', { class: 'flags' }, chips));

  if (active.has('self_harm')) {
    const step = (n, text) => el('li', {}, text);
    parts.push(el('div', { class: 'card crisis' },
      el('div', { class: 'card-title' }, L('TA 可能撑得很辛苦', 'They may be really struggling')),
      el('div', { class: 'card-text' }, L('AI 判断不一定准，请对照原话', 'AI can be wrong — check their actual words')),
      el('ol', { class: 'steps' },
        step(1, L('先接住 TA：温和地问一句「你现在安全吗？」', 'Reach out first: gently ask, "Are you safe right now?"')),
        step(2, L('陪着 TA，认真听，不急着讲道理', "Stay with them and listen — don't rush to give advice")),
        step(3, L('如果 TA 提到具体打算、正在伤害自己或突然联系不上，马上联系 TA 身边的人，或拨打当地的急救电话（美国是 911）',
          'If they mention a plan, are hurting themselves, or suddenly go silent, contact someone near them right away or call 911 (or your local emergency number)'))),
      el('div', { class: 'hotline' }, el('span', {}, L('美国：电话或短信', 'Call or text (US)')), el('b', {}, '988')),
      el('div', { class: 'hotline' }, el('span', {}, L('危机短信热线', 'Crisis Text Line')), el('b', {}, 'HOME → 741741')),
      el('div', { class: 'card-text', style: 'margin-top:6px' }, L('其他国家和地区：findahelpline.com', 'Outside the US: findahelpline.com'))));
  }
  if (active.has('asks_money') || r.reading === '可疑') {
    parts.push(el('div', { class: 'card money' },
      el('div', { class: 'card-title' }, L('这条消息涉及付款或账户信息', 'This message is about payments or account details')),
      el('div', { class: 'card-text' }, L('对方说收款账户换了、或要你付款、要验证码时，先用你之前存的电话或邮箱联系 TA 本人核实，别直接回这条消息。改收款账户是外贸里最常见的骗局。',
        'If they say their bank account changed, ask you to pay, or ask for a code, confirm with them through a phone number or email you already had — not by replying here. A "new bank account" is the most common trade scam.'))));
  }

  const rows = [];
  if (r.realMeaning) rows.push(el('div', { class: 'k' }, L('其实是', 'Means')), el('div', { class: 'means' }, r.realMeaning));
  if (r.literal) rows.push(el('div', { class: 'k' }, L('直译', 'Literally')), el('div', {}, r.literal));
  if (r.cultureNote) rows.push(el('div', { class: 'k' }, L('为什么', 'Why')), el('div', {}, r.cultureNote));
  if (r.confidence) {
    const words = { 3: L('很有把握', 'Quite sure'), 2: L('比较有把握', 'Fairly sure'), 1: L('不太确定，结合上下文再看', 'Not sure — check the context') };
    rows.push(el('div', { class: 'k' }, L('把握', 'Sure?')), el('div', {}, el('span', { class: 'dots' }, '●'.repeat(r.confidence) + '○'.repeat(3 - r.confidence)), words[r.confidence]));
  }
  const color = READING_COLOR(r.reading);
  parts.push(el('div', { class: 'card between' },
    el('div', { class: 'head' }, el('span', {}, L('话外音', 'Between the lines')),
      r.reading ? el('span', { class: 'badge', style: `color:${color};background:${tint(color, 14)}` }, label(r.reading, 'readings')) : null),
    el('div', { class: 'kv' }, rows)));

  if (r.suggestedReply) {
    parts.push(el('div', { class: 'card suggestion' },
      el('div', { class: 'head' }, el('span', {}, L('建议', 'Suggestion')), el('span', { class: 'resp' }, label(r.bestResponse, 'responses'))),
      el('div', { class: 'reply' }, r.suggestedReply),
      r.replyGloss ? el('div', { class: 'gloss' }, L('意思：', 'Means: ') + r.replyGloss) : null,
      el('div', { class: 'copy-row' }, el('span', {}, L('可以这样回，按你的习惯改一改', 'You could say this — tweak it to sound like you')),
        el('button', { class: 'pill copy', onclick: e => { api.copy(r.suggestedReply); e.target.textContent = L('已复制', 'Copied'); } }, L('复制', 'Copy')))));
  }
  parts.push(el('div', { class: 'engine' }, `${r.engine} · ${(r.latencyMs / 1000).toFixed(1)}s`));
  return parts;
}

function renderRecent() {
  const list = $('recentList');
  $('recent').classList.toggle('hidden', state.reports.length < 2);
  list.replaceChildren(...state.reports.slice(0, 12).map((r, i) => el('div', {
    class: 'recent-item' + (i === state.shown ? ' on' : ''), onclick: () => { state.shown = i; render(); $('content').scrollTop = 0; },
  }, el('span', { class: 'mark', style: `background:${READING_COLOR(r.reading)}` }), el('b', {}, label(r.reading, 'readings') || '—'),
  el('span', { class: 'text' }, r.message.text), el('span', { class: 'time' }, time(r.date)))));
}

// MARK: - 分析队列

async function analyze(context, latest) {
  state.pending = { context, latest };
  if (state.analyzing) return;
  state.analyzing = true;
  render();
  while (state.pending) {
    const job = state.pending;
    state.pending = null;
    const result = await api.analyze(job.context, job.latest);
    if (result.error) { state.error = result.error; continue; }
    state.error = null;
    const report = result.report;
    report.active = await api.activeFlags(report);
    state.reports.unshift(report);
    state.reports = state.reports.slice(0, 30);
    state.shown = 0;
  }
  state.analyzing = false;
  render();
  $('content').scrollTop = 0;
}

// MARK: - 粘贴模式

async function analyzePaste() {
  const text = $('transcript').value.trim();
  if (!text) return;
  const parsed = await api.parseTranscript(text);
  const index = parsed.messages.map(m => m.speaker).lastIndexOf('them');
  if (index < 0) {
    state.error = L('没找到对方发的消息。如果整段都是你自己说的，就没什么可分析的。', "No messages from them found. If it's all you talking, there's nothing to analyze.");
    render();
    return;
  }
  const latest = parsed.messages[index];
  if (latest.sender === 'Them') latest.sender = null;   // 截图认不出名字时的占位名
  analyze(parsed.messages.slice(0, index).slice(-10), latest);
}

async function readScreenshot(dataURL) {
  state.mode = 'paste';
  state.error = null;
  $('transcript').value = L('正在识别截图…', 'Reading the screenshot…');
  render();
  const result = await api.ocr(dataURL, false);
  if (result.error || !result.transcript) {
    $('transcript').value = '';
    state.error = result.error || L('截图里没认出文字。换一张清楚点的试试。', "Couldn't find any text in that screenshot. Try a clearer one.");
    render();
    return;
  }
  $('transcript').value = result.transcript;
  updatePasteCount();
  analyzePaste();
}

async function updatePasteCount() {
  const text = $('transcript').value.trim();
  if (!text) { $('pasteCount').textContent = ''; return; }
  const parsed = await api.parseTranscript(text);
  const theirs = parsed.messages.filter(m => m.speaker === 'them').length;
  const n = parsed.messages.length;
  $('pasteCount').textContent = L(`${n} 条 · 对方 ${theirs} 条`, `${n === 1 ? '1 message' : `${n} messages`} · ${theirs} from them`);
}

const fileToDataURL = file => new Promise(resolve => { const r = new FileReader(); r.onload = () => resolve(r.result); r.readAsDataURL(file); });

// MARK: - 实时模式

const live = { running: false, stream: null, timer: null, lastHash: null, candidate: null, replay: null, tick: 0, busy: false };

async function showWindowPicker() {
  const list = $('windowList');
  list.replaceChildren(el('div', { class: 'hint' }, L('正在列出窗口…', 'Listing windows…')));
  const windows = await api.windows();
  list.replaceChildren(...windows.map(w => el('button', { class: 'window', onclick: () => startLive(w) },
    w.thumbnail ? el('img', { src: w.thumbnail }) : null, el('div', {}, w.name))));
  if (!windows.length) list.replaceChildren(el('div', { class: 'hint' }, L('没找到窗口。', 'No windows found.')));
}

async function startLive(chosen) {
  stopLive();
  state.error = null;
  live.replay = await api.replayFrames();
  if (!live.replay) {
    if (chosen) { await api.chooseWindow(chosen.id, chosen.name); S.windowName = chosen.name; }
    try {
      live.stream = await navigator.mediaDevices.getDisplayMedia({ video: true, audio: false });
    } catch (error) {
      state.error = (S.platform === 'darwin'
        ? L('没能看这个窗口。在 系统设置 → 隐私与安全性 → 屏幕与系统录音 里允许 Undertone，再试一次。', "Couldn't read that window. Allow Undertone under System Settings → Privacy & Security → Screen & System Audio Recording, then try again.")
        : L('没能看这个窗口，换一个窗口试试。', "Couldn't read that window. Try another one.")) + ` (${error.message})`;
      render();
      return;
    }
    const video = $('video');
    video.srcObject = live.stream;
    await video.play();
    live.stream.getVideoTracks()[0].addEventListener('ended', () => { stopLive(); render(); });
  } else {
    S.windowName = 'replay';
  }
  live.running = true;
  state.paused = false;
  state.lastAnalyzed = null;
  live.lastHash = live.candidate = null;
  live.timer = setInterval(tick, Math.max(1, S.interval) * 1000);
  render();
  tick();
}

function stopLive() {
  clearInterval(live.timer);
  live.timer = null;
  if (live.stream) live.stream.getTracks().forEach(t => t.stop());
  live.stream = null;
  live.running = false;
}

/** 取一帧，去掉顶部和底部，返回 { png, hash }。 */
async function grabFrame() {
  const canvas = $('canvas');
  let source, w, h;
  if (live.replay) {
    const index = Math.min(live.replay.length - 1, Math.floor(live.tick / 3));
    source = await new Promise(resolve => { const img = new Image(); img.onload = () => resolve(img); img.src = live.replay[index]; });
    w = source.naturalWidth; h = source.naturalHeight;
  } else {
    source = $('video');
    w = source.videoWidth; h = source.videoHeight;
  }
  if (!w || !h) return null;
  // 回放的截图已经只剩聊天区域，不再裁
  const cropTop = live.replay ? 0 : S.cropTop;
  const cropBottom = live.replay ? 0 : S.cropBottom;
  const top = Math.round(h * cropTop / 100);
  const height = Math.max(1, Math.round(h * (1 - (cropTop + cropBottom) / 100)));
  canvas.width = w; canvas.height = height;
  const ctx = canvas.getContext('2d', { willReadFrequently: true });
  ctx.drawImage(source, 0, top, w, height, 0, 0, w, height);
  // 32×32 的灰度缩略图当指纹：画面没变就不做 OCR
  const small = document.createElement('canvas');
  small.width = small.height = 32;
  const sctx = small.getContext('2d', { willReadFrequently: true });
  sctx.drawImage(canvas, 0, 0, 32, 32);
  const pixels = sctx.getImageData(0, 0, 32, 32).data;
  let hash = '';
  for (let i = 0; i < pixels.length; i += 4) hash += String.fromCharCode(48 + Math.round((pixels[i] + pixels[i + 1] + pixels[i + 2]) / 3 / 16));
  return { png: canvas.toDataURL('image/png'), hash };
}

async function tick() {
  if (!live.running || state.paused || live.busy) return;
  live.busy = true;
  try {
    const frame = await grabFrame();
    live.tick++;
    if (!frame || frame.hash === live.lastHash) return;
    // 画面刚变时可能还在滚动：等下一次看到同样的画面再读
    if (frame.hash !== live.candidate) { live.candidate = frame.hash; return; }
    live.lastHash = frame.hash;
    const result = await api.ocr(frame.png, true);
    if (result.error) { state.error = result.error; render(); return; }
    const messages = result.messages;
    state.liveMessages = messages;
    const index = messages.map(m => m.speaker).lastIndexOf('them');
    if (index < 0) return;
    const latest = messages[index];
    if (state.lastAnalyzed && layoutTools.similarity(latest.text, state.lastAnalyzed) >= 0.85) return;
    state.lastAnalyzed = latest.text;
    analyze(messages.slice(0, index).slice(-10), latest);
  } finally {
    live.busy = false;
  }
}

// MARK: - 发之前看看

async function checkDraft() {
  const draft = $('draftText').value.trim();
  if (!draft) return;
  let context = state.liveMessages;
  if (state.mode === 'paste' && $('transcript').value.trim()) context = (await api.parseTranscript($('transcript').value)).messages;
  const result = $('draftResult');
  $('checkDraft').disabled = true;
  $('checkDraft').textContent = L('正在看…', 'Checking…');
  result.replaceChildren();
  const response = await api.checkDraft(context.slice(-10), draft);
  $('checkDraft').disabled = false;
  $('checkDraft').textContent = L('帮我看看', 'Check it');
  if (response.error) { result.replaceChildren(el('div', { class: 'hint' }, response.error)); return; }
  const r = response.review;
  const ok = r.verdict === '得体';
  const rows = [];
  if (r.landsAs) rows.push(el('div', { class: 'k' }, L('对方读来', 'Lands as')), el('div', {}, r.landsAs));
  if (r.issues) rows.push(el('div', { class: 'k' }, L('问题', 'Issue')), el('div', {}, r.issues));
  result.replaceChildren(
    el('div', { class: 'verdict ' + (ok ? 'ok' : 'warn') }, (ok ? '✓ ' : '! ') + label(r.verdict, 'verdicts')),
    el('div', { class: 'kv' }, rows),
    r.rewriteDiffers ? el('div', { class: 'row' }, el('span', { class: 'k', style: 'color:var(--faint)' }, L('可以改成', 'Try')), el('div', { class: 'reply' }, r.rewrite)) : null,
    r.rewriteDiffers && r.rewriteGloss ? el('div', { class: 'gloss' }, L('意思：', 'Means: ') + r.rewriteGloss) : null,
    r.rewriteDiffers ? el('div', { class: 'row' }, el('span', { class: 'spacer' }),
      el('button', { class: 'pill copy', onclick: e => { api.copy(r.rewrite); e.target.textContent = L('已复制', 'Copied'); } }, L('复制', 'Copy'))) : null);
  result.scrollIntoView({ behavior: 'smooth', block: 'nearest' });
}

// MARK: - 设置

function openSettings() {
  $('uiSelect').value = ui;
  $('explainSelect').replaceChildren(...S.languages.map(([code, name]) => el('option', { value: code }, name)));
  $('explainSelect').value = S.explanationResolved;
  $('modelInput').value = S.model;
  $('urlInput').value = S.ollamaURL;
  $('topCheck').checked = !!S.alwaysOnTop;
  $('cropTopInput').value = S.cropTop;
  $('cropBottomInput').value = S.cropBottom;
  $('settings').classList.remove('hidden');
}

async function closeSettings() {
  const uiChoice = $('uiSelect').value;
  const explain = $('explainSelect').value;
  await api.save({
    ui: uiChoice,
    // 解释语言选得和界面一样时，记成「跟着界面」
    explanation: explain === uiChoice ? null : explain,
    model: $('modelInput').value.trim() || 'qwen3.5:4b',
    ollamaURL: $('urlInput').value.trim() || 'http://127.0.0.1:11434',
    alwaysOnTop: $('topCheck').checked,
    cropTop: Math.min(45, Math.max(0, Number($('cropTopInput').value) || 0)),
    cropBottom: Math.min(45, Math.max(0, Number($('cropBottomInput').value) || 0)),
  });
  S = await api.settings();
  ui = S.uiResolved;
  $('settings').classList.add('hidden');
  applyTexts();
  render();
}

// MARK: - 启动

async function setMode(mode) {
  state.mode = mode;
  state.error = null;
  await api.save({ mode });
  if (mode === 'live' && !live.running) {
    if (await api.replayFrames()) startLive();
    else showWindowPicker();
  }
  if (mode === 'paste') { stopLive(); state.paused = false; }
  render();
}

async function main() {
  S = await api.settings();
  ui = S.uiResolved;
  applyTexts();
  $('liveTab').onclick = () => setMode('live');
  $('pasteTab').onclick = () => setMode('paste');
  $('pauseButton').onclick = () => { state.paused = !state.paused; if (!state.paused) tick(); render(); };
  $('settingsButton').onclick = openSettings;
  $('closeSettings').onclick = closeSettings;
  $('changeWindow').onclick = () => { $('settings').classList.add('hidden'); stopLive(); state.mode = 'live'; showWindowPicker(); render(); };
  $('refreshWindows').onclick = showWindowPicker;
  $('analyzePaste').onclick = analyzePaste;
  $('clearPaste').onclick = () => { $('transcript').value = ''; updatePasteCount(); };
  $('transcript').addEventListener('input', updatePasteCount);
  $('pasteImage').onclick = async () => {
    const image = await api.clipboardImage();
    if (image) readScreenshot(image);
    else { state.error = L('剪贴板里没有图片。先截一张聊天或邮件的图。', 'No image on the clipboard. Take a screenshot of the chat or email first.'); render(); }
  };
  $('transcript').addEventListener('paste', async event => {
    const item = [...event.clipboardData.items].find(i => i.type.startsWith('image/'));
    if (item) { event.preventDefault(); readScreenshot(await fileToDataURL(item.getAsFile())); }
  });
  document.addEventListener('dragover', e => e.preventDefault());
  document.addEventListener('drop', async e => {
    e.preventDefault();
    const file = [...e.dataTransfer.files].find(f => f.type.startsWith('image/'));
    if (file) readScreenshot(await fileToDataURL(file));
  });
  $('checkDraft').onclick = checkDraft;
  $('clearDraft').onclick = () => { $('draftText').value = ''; $('draftResult').replaceChildren(); };
  await setMode(S.mode === 'live' && (S.windowName || await api.replayFrames()) ? 'live' : 'paste');
}

main();
