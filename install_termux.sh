#!/data/data/com.termux/files/usr/bin/bash
# 团图 · Termux 一键安装（在旧手机 Termux 里、项目目录下执行：bash install_termux.sh）
# 需要手机先连上家里的 Wi-Fi（要联网下载依赖，装完就彻底离线可用）
#
# 国内网络默认走清华 TUNA 镜像加速；要禁用：TUANTU_MIRROR=off bash install_termux.sh
set -e
cd "$(dirname "$0")"
echo "==> 团图安装开始，目录：$(pwd)"

if [ "${TUANTU_MIRROR:-cn}" = "cn" ]; then
  echo "==> 切换 Termux 主源到清华 TUNA 镜像"
  mkdir -p "$PREFIX/etc/apt"
  echo "deb https://mirrors.tuna.tsinghua.edu.cn/termux/apt/termux-main stable main" \
    > "$PREFIX/etc/apt/sources.list"
fi

echo "==> [1/4] 安装 Termux 基础组件"
pkg update -y
pkg install -y proot-distro
pkg install -y qrencode || echo "（qrencode 不可用，跳过终端二维码，不影响功能）"

echo "==> [2/4] 安装 Debian 环境（首次约 3~5 分钟）"
if [ -d "$PREFIX/var/lib/proot-distro/containers/debian" ] ||
   [ -d "$PREFIX/var/lib/proot-distro/installed-rootfs/debian" ]; then
  echo "（Debian 已装过，跳过）"
elif [ "${TUANTU_MIRROR:-cn}" = "cn" ]; then
  # Docker Hub 国内被墙，走 DaoCloud 镜像拉 Debian rootfs
  proot-distro install -n debian docker.m.daocloud.io/library/debian:12
else
  proot-distro install debian
fi

echo "==> [3/4] 在 Debian 里装 Python 依赖 / ffmpeg / exiftool / 人脸模型（需联网）"
proot-distro login debian --bind "$(pwd):/root/tuantu" -- /bin/bash -e <<'EOS'
export DEBIAN_FRONTEND=noninteractive
if [ "${TUANTU_MIRROR:-cn}" = "cn" ]; then
  echo "==> 切换 Debian / PyPI 源到清华 TUNA 镜像"
  sed -i 's@deb.debian.org@mirrors.tuna.tsinghua.edu.cn@g' /etc/apt/sources.list 2>/dev/null || true
  sed -i 's@deb.debian.org@mirrors.tuna.tsinghua.edu.cn@g' /etc/apt/sources.list.d/* 2>/dev/null || true
  python3 -m pip config set global.index-url https://pypi.tuna.tsinghua.edu.cn/simple
fi
apt-get update -y
apt-get install -y python3-pip ffmpeg exiftool libgl1 libglib2.0-0 openssl iproute2
# 升级 pip 以正确解析 aarch64 二进制 wheel；--only-binary 强制不编译源码包；
# 容器环境直接 --break-system-packages 绕过 PEP 668
python3 -m pip install --upgrade --break-system-packages pip
python3 -m pip install --no-cache-dir --only-binary=:all: --break-system-packages \
  -r /root/tuantu/requirements.txt
python3 /root/tuantu/scripts/download_models.py
EOS

echo "==> [4/4] 检查"
proot-distro login debian --bind "$(pwd):/root/tuantu" -- /bin/bash -c \
  "python3 -c 'import fastapi, cv2, PIL; print(\"依赖 OK, opencv\", cv2.__version__)'"

echo ""
echo "✅ 安装完成！以后每次出行："
echo "   1. Termux 里执行  ./run.sh"
echo "   2. 手机开热点（记得选 5GHz），屏幕上会出现二维码"
echo "   3. 队友连上热点扫码进入"
