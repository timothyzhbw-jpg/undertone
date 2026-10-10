#!/usr/bin/env node
// 开发用：通过 DevTools 协议操作正在运行的桌面版（npx electron . --remote-debugging-port=9223）。
//   node tools/cdp.js eval "表达式"     在界面里执行，打印结果
//   node tools/cdp.js shot 输出.png      截下面板
'use strict';
const fs = require('fs');

async function main([command, arg, port = '9223']) {
  const pages = await (await fetch(`http://127.0.0.1:${port}/json`)).json();
  const page = pages.find(p => p.type === 'page');
  const ws = new WebSocket(page.webSocketDebuggerUrl);
  await new Promise(resolve => ws.addEventListener('open', resolve));
  let id = 0;
  const call = (method, params = {}) => new Promise(resolve => {
    const me = ++id;
    ws.addEventListener('message', function onMessage(event) {
      const msg = JSON.parse(event.data);
      if (msg.id === me) { ws.removeEventListener('message', onMessage); resolve(msg.result || msg); }
    });
    ws.send(JSON.stringify({ id: me, method, params }));
  });
  if (command === 'eval') {
    const r = await call('Runtime.evaluate', { expression: arg, awaitPromise: true, returnByValue: true });
    console.log(JSON.stringify(r.result ? r.result.value : r, null, 1));
  } else if (command === 'shot') {
    const r = await call('Page.captureScreenshot', { format: 'png' });
    fs.writeFileSync(arg, Buffer.from(r.data, 'base64'));
    console.log(arg);
  }
  ws.close();
}
main(process.argv.slice(2)).catch(e => { console.error(e.message); process.exit(1); });
