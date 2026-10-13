#!/data/data/com.termux/files/usr/bin/bash
# 团图 · 启动脚本（Termux 里执行 ./run.sh）
cd "$(dirname "$0")"

# 保持后台不被杀（配合系统设置里关掉 Termux 的电池优化）
termux-wake-lock 2>/dev/null || true
trap 'termux-wake-unlock 2>/dev/null' EXIT

# 找出本机所有局域网 IP（Termux 没有 ip 命令，借 Debian 的查）
ADDRS=$(proot-distro login debian -- /bin/bash -c "ip -4 addr 2>/dev/null" 2>/dev/null \
  | grep -o 'inet [0-9.]*' | cut -d' ' -f2 | grep -v '^127\.' || true)
[ -z "$ADDRS" ] && ADDRS="192.168.43.1"

clear
echo ""
echo "  🏕️  团图启动中 · 队友连接本机热点后，扫码或输入网址进入："
echo ""

# 生成 HTTPS 证书（首次自动；Web Share「存储图像进相册」要求 https）
SCHEME="http"
if proot-distro login debian --bind "$(pwd):/root/tuantu" -- /bin/bash -c \
     'python3 /root/tuantu/scripts/make_cert.py' ; then
  if [ -f data/certs/tuantu.crt ]; then
    SCHEME="https"
    echo "  🔒 已启用 HTTPS（存相册可用）。"
    echo "  ⚠️  队友首次打开会提示「不安全」——证书是盒子自己签的，"
    echo "     点「高级/显示详细信息 → 继续访问」即可，每台手机一次。"
    echo ""
  fi
fi

for a in $ADDRS; do
  URL="$SCHEME://$a:8000"
  echo "  ➜  $URL"
  echo ""
  qrencode -t ANSIUTF8 "$URL" 2>/dev/null || echo "  （装 qrencode 可显示二维码：pkg install qrencode）"
  echo ""
done
echo "  管理台：上边任一网址后加 /admin（口令见 config.py，默认 admin）"
echo "  停止：按 Ctrl+C。别锁屏前关掉 Termux 通知。"
echo ""

if [ "$SCHEME" = "https" ]; then
  proot-distro login debian --bind "$(pwd):/root/tuantu" -- /bin/bash -c \
    'cd /root/tuantu && exec python3 -m uvicorn server.main:app --host 0.0.0.0 --port 8000 --ssl-certfile data/certs/tuantu.crt --ssl-keyfile data/certs/tuantu.key'
else
  proot-distro login debian --bind "$(pwd):/root/tuantu" -- /bin/bash -c \
    'cd /root/tuantu && exec python3 -m uvicorn server.main:app --host 0.0.0.0 --port 8000'
fi
