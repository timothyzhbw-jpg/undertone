# Trying the Linux build in Docker

Ubuntu 24.04 with a virtual display (Xvfb), a window manager (Openbox: without one, Chromium can't list windows to capture) and Electron's system libraries. Ollama runs on the host.

```bash
npm run dist:linux -- --dir --arm64          # or build the .deb / AppImage
docker build -t undertone-linux-test test/linux
docker run -d --name ut --shm-size=1g -v "$PWD":/app:ro -v /path/to/chats:/chat:ro undertone-linux-test sleep infinity
docker exec ut sh /app/test/linux/start.sh   # virtual display, a "chat window" showing /chat/chat.png, Undertone
CDP='ELECTRON_RUN_AS_NODE=1 /app/dist/linux-arm64-unpacked/undertone-desktop /app/tools/cdp.js'
docker exec ut sh -c "$CDP shot /tmp/panel.png 9225"
```

Drive the panel with `$CDP eval "…" 9225`, for example click Live, pick the "Chat with John" window, and read `#report`. For x64, build the image with `--platform linux/amd64`; AppImages under emulation need the three bytes at offset 8 zeroed first (`printf '\0\0\0' | dd of=app.AppImage bs=1 seek=8 conv=notrunc`), which real x64 Linux doesn't.
