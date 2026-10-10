# 在真正的 Linux（Ubuntu 24.04）里跑桌面版：Xvfb 虚拟显示器 + Electron 需要的系统库。
# 用法见 test/linux/README.md。
FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      xvfb xauth dbus-x11 feh imagemagick x11-utils openbox \
      libgtk-3-0t64 libnss3 libasound2t64 libgbm1 libxss1 libxtst6 libatk-bridge2.0-0t64 libdrm2 libxkbcommon0 \
      libxcomposite1 libxdamage1 libxrandr2 libcups2t64 libpango-1.0-0 libcairo2 libsecret-1-0 \
      fonts-dejavu-core fonts-noto-cjk ca-certificates \
    && rm -rf /var/lib/apt/lists/*
RUN useradd -m tester
USER tester
WORKDIR /home/tester
