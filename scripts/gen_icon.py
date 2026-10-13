"""生成 PWA 图标 + 通用占位缩略图（一次性运行，产物直接提交进仓库）。"""
from pathlib import Path

from PIL import Image, ImageDraw

S = 512
OUT = Path(__file__).resolve().parent.parent / "server" / "static" / "icons"
OUT.mkdir(parents=True, exist_ok=True)


def gradient_base(top, bottom):
    img = Image.new("RGB", (S, S))
    d = ImageDraw.Draw(img)
    for y in range(S):
        t = y / S
        d.line([(0, y), (S, y)],
               fill=tuple(int(a + (b - a) * t) for a, b in zip(top, bottom)))
    return img, d


def rounded(img):
    mask = Image.new("L", (S, S), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, S, S], radius=100, fill=255)
    out = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    out.paste(img, (0, 0), mask)
    return out


# ---------- App 图标：粉紫渐变 + 相机 ----------
img, d = gradient_base((255, 94, 122), (120, 53, 220))
d.rounded_rectangle([196, 140, 316, 184], radius=20, fill=(15, 18, 22))   # 顶取景器
d.rounded_rectangle([96, 172, 416, 388], radius=36, fill=(15, 18, 22))    # 机身
d.ellipse([166, 220, 346, 400 - 30], fill=(255, 255, 255))                # 镜头外圈
d.ellipse([206, 260, 306, 360], fill=(56, 189, 248))                      # 镜片
d.ellipse([356, 200, 388, 232], fill=(255, 255, 255))                     # 闪光灯
rounded(img).save(OUT / "icon-512.png")
icon512 = Image.open(OUT / "icon-512.png")
icon512.resize((192, 192), Image.LANCZOS).save(OUT / "icon-192.png")

# ---------- 通用占位缩略图（图片解码失败时前端兜底显示） ----------
ph, d = gradient_base((40, 46, 56), (24, 28, 34))
d.polygon([(120, 330), (216, 214), (292, 300), (340, 250), (420, 330)], fill=(90, 100, 115))
d.ellipse([330, 150, 380, 200], fill=(255, 209, 102))  # 太阳
d.text((210, 400), "无法预览", fill=(139, 150, 165))
ph.save(OUT / "ph.png")

print("icons written to", OUT)
