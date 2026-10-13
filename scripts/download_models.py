"""下载 OpenCV Zoo 人脸模型（YuNet 检测 + SFace 特征）。

部署机（旧手机）需要在有网的候跑一次；模型文件也可以直接从电脑拷过去。
"""
import sys
import urllib.request
from pathlib import Path

OUT = Path(__file__).resolve().parent.parent / "models"
OUT.mkdir(exist_ok=True)

FILES = {
    "yunet.onnx": "https://github.com/opencv/opencv_zoo/raw/main/models/face_detection_yunet/face_detection_yunet_2023mar.onnx",
    "sface.onnx": "https://github.com/opencv/opencv_zoo/raw/main/models/face_recognition_sface/face_recognition_sface_2021dec.onnx",
}

for name, url in FILES.items():
    dst = OUT / name
    if dst.exists() and dst.stat().st_size > 100_000:
        print(f"[skip] {name} 已存在")
        continue
    print(f"[down] {name} ...")
    try:
        urllib.request.urlretrieve(url, dst)
        print(f"  ok, {dst.stat().st_size // 1024} KB")
    except Exception as e:
        print(f"  失败: {e}", file=sys.stderr)
        sys.exit(1)
print("done")
