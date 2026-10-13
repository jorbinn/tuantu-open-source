"""生成自签名 HTTPS 证书（SAN 带上当前热点/局域网 IP）。

用途：Web Share API（「存储图像」直接进相册）只在 HTTPS 安全上下文里可用，
所以盒子默认走 https。自签证书在手机上首次访问时浏览器会警告一次，
点「继续访问」即可（整个过程不出外网，不装任何东西）。

依赖 openssl 命令行（Debian proot / Git Bash / macOS 都自带）。
"""
import re
import shutil
import subprocess
import sys
from pathlib import Path

BASE = Path(__file__).resolve().parent.parent
OUT = BASE / "data" / "certs"


def detect_ips() -> list[str]:
    ips: set[str] = set()
    try:  # Linux / proot Debian
        out = subprocess.run(["ip", "-4", "addr"], capture_output=True, text=True)
        ips.update(re.findall(r"inet (\d+\.\d+\.\d+\.\d+)", out.stdout))
    except Exception:
        pass
    if not ips:  # Windows
        try:
            out = subprocess.run(["ipconfig"], capture_output=True)
            text = out.stdout.decode("gbk", "replace")
            ips.update(re.findall(r"IPv4[^\n]*?(\d+\.\d+\.\d+\.\d+)", text))
        except Exception:
            pass
    try:  # 兜底：UDP 连接探测默认路由地址（离线时可能失败）
        import socket
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("10.255.255.255", 1))
        ips.add(s.getsockname()[0])
        s.close()
    except Exception:
        pass
    ips.discard("127.0.0.1")
    return sorted(ips)


def main() -> int:
    crt, key = OUT / "tuantu.crt", OUT / "tuantu.key"
    if crt.exists() and key.exists():
        print("[cert] 证书已存在，跳过")
        return 0
    openssl = shutil.which("openssl")
    if not openssl:
        print("[cert] 没找到 openssl，无法生成 HTTPS 证书（将以 http 启动）")
        return 1
    OUT.mkdir(parents=True, exist_ok=True)
    san = ",".join(["DNS:localhost"] + [f"IP:{i}" for i in detect_ips()])
    subprocess.run(
        [openssl, "req", "-x509", "-newkey", "rsa:2048", "-nodes",
         "-keyout", str(key), "-out", str(crt), "-days", "3650",
         "-subj", "/CN=tuantu", "-addext", f"subjectAltName={san}"],
        check=True, capture_output=True)
    print(f"[cert] HTTPS 证书生成 OK（SAN: {san or '无 IP'}）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
