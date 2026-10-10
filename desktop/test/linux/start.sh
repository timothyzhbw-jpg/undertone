#!/bin/sh
# 容器里：开虚拟显示器，放一个「聊天窗口」（一张聊天截图），再启动 Undertone（远程调试端口 9225）。
set -e
export DISPLAY=:99
Xvfb :99 -screen 0 1600x1000x24 >/tmp/xvfb.log 2>&1 &
sleep 1
# 真实桌面都有窗口管理器；没有它 Chromium 列不出窗口（靠 _NET_CLIENT_LIST）
openbox >/tmp/openbox.log 2>&1 &
sleep 1
mkdir -p "$HOME/.config/Undertone Desktop"
cat > "$HOME/.config/Undertone Desktop/settings.json" <<JSON
{"ui": "${UI:-en}", "relationship": "客户", "mode": "paste", "alwaysOnTop": false,
 "ollamaURL": "http://host.docker.internal:11434", "cropTop": 0, "cropBottom": 0, "interval": 2}
JSON
feh --title "Chat with John" --geometry 520x590+760+40 --zoom fill /chat/chat.png >/tmp/feh.log 2>&1 &
/app/dist/linux-arm64-unpacked/undertone-desktop --no-sandbox --disable-dev-shm-usage --remote-debugging-port=9225 >/tmp/undertone.log 2>&1 &
echo started
