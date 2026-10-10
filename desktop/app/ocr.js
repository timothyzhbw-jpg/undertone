// OCR 和版面：Tesseract 读出每一行文字和位置，再按位置拼成聊天气泡。
// Mac 版用 Apple Vision 加像素级的气泡检测；这里简化成按行的左右位置分：贴左边的是对方，贴右边的是自己，
// 居中的短行（日期、时间、「已读」）跳过。邮件、整页文字这种只有一边的，交给 screenshotTranscript 连成一条。
'use strict';

const path = require('path');
const { layout } = require('./layout');

let workerPromise = null;

/** 打包后 node_modules 在 app.asar 里，Tesseract 的 wasm 和语言数据要从解包目录读。 */
const unpacked = p => p.replace(`app.asar${path.sep}`, `app.asar.unpacked${path.sep}`);

function worker() {
  if (!workerPromise) {
    const { createWorker } = require('tesseract.js');
    const langPath = unpacked(path.join(path.dirname(require.resolve('@tesseract.js-data/eng/package.json')), '4.0.0_best_int'));
    const { app } = require('electron');
    workerPromise = createWorker('eng', 1, { langPath, gzip: true, cachePath: app.getPath('userData') });
  }
  return workerPromise;
}

/**
 * 识别前先变成黑白：深色的字变黑，彩色气泡、头像、浅灰背景都变白。
 * 不这样做时，Tesseract 会把整块绿色气泡当成图片跳过，头像被认成「BH」。深色主题先反色。
 * 小图放大到两倍：Windows 常见的 100% 缩放下字只有十几像素高，Tesseract 认不准。
 */
function prepare(png) {
  const { nativeImage } = require('electron');
  let image = nativeImage.createFromBuffer(png);
  const size = image.getSize();
  if (size.width < 1200) image = image.resize({ width: size.width * 2, quality: 'best' });
  const { width, height } = image.getSize();
  const pixels = image.toBitmap();               // BGRA
  const luminance = new Float32Array(width * height);
  let sum = 0;
  for (let i = 0, p = 0; i < luminance.length; i++, p += 4) {
    luminance[i] = 0.114 * pixels[p] + 0.587 * pixels[p + 1] + 0.299 * pixels[p + 2];
    sum += luminance[i];
  }
  const dark = sum / luminance.length < 110;
  for (let i = 0, p = 0; i < luminance.length; i++, p += 4) {
    const l = dark ? 255 - luminance[i] : luminance[i];
    const v = l < 128 ? 0 : 255;
    pixels[p] = pixels[p + 1] = pixels[p + 2] = v;
    pixels[p + 3] = 255;
  }
  return { png: nativeImage.createFromBitmap(pixels, { width, height }).toPNG(), width };
}

async function read(input) {
  const w = await worker();
  const { png, width } = prepare(input);
  const { data } = await w.recognize(png, {}, { blocks: true });
  const lines = [];
  for (const block of data.blocks || []) {
    for (const paragraph of block.paragraphs || []) {
      for (const l of paragraph.lines || []) {
        lines.push({ text: l.text.trim(), confidence: l.confidence, ...l.bbox,
          words: (l.words || []).map(word => ({ text: word.text, confidence: word.confidence, x0: word.bbox.x0, x1: word.bbox.x1 })) });
      }
    }
  }
  const messages = layout(lines, width);
  return { messages, lines: lines.filter(l => l.text).sort((a, b) => a.y0 - b.y0).map(l => l.text) };
}

async function close() {
  if (workerPromise) (await workerPromise).terminate().catch(() => {});
}

module.exports = { read, close };
