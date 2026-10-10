// 用 Electron 跑一遍真实的 OCR（黑白化要用 Electron 的 nativeImage）：npx electron test/ocr-check.js 截图.png
'use strict';
const { app } = require('electron');
const core = require('../core/undertone');
app.whenReady().then(async () => {
  const ocr = require('../app/ocr');
  for (const file of process.argv.slice(2).filter(a => a.endsWith('.png'))) {
    const t = Date.now();
    const result = await ocr.read(require('fs').readFileSync(file));
    console.log(`== ${file} (${Date.now() - t} ms)`);
    for (const m of result.messages) console.log(m.speaker.padEnd(5), m.text);
    console.log('-- transcript:\n' + core.screenshotTranscript(result.messages, result.lines));
  }
  await ocr.close();
  app.quit();
});
