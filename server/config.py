"""全局配置。改这里的常量即可定制，无需动其他代码。"""
import os
from pathlib import Path

BASE_DIR = Path(__file__).resolve().parent.parent
DATA_DIR = Path(os.environ.get("TUANTU_DATA", BASE_DIR / "data"))
ORIG_DIR = DATA_DIR / "orig"       # 原始文件
THUMB_DIR = DATA_DIR / "thumbs"    # 缩略图 webp
AVATAR_DIR = DATA_DIR / "avatars"  # 用户头像 webp
DB_PATH = DATA_DIR / "tuantu.db"
MODEL_DIR = BASE_DIR / "models"    # yunet / sface onnx

ROOM_CODE = os.environ.get("TUANTU_ROOM_CODE", "")          # 队员口令；留空 = 不需要（热点里都是自己人）
ADMIN_CODE = os.environ.get("TUANTU_ADMIN_CODE", "admin")   # 管理端口令

HOST = "0.0.0.0"
PORT = 8000

BATCH_SIZE = 30            # 每批发牌张数
THUMB_SIZE = 480           # 缩略图长边
VIDEO_FRAME_AT = 1.0       # 视频抽帧秒数（取不到就退到 0）

# 允许上传的扩展名（图片/视频/音频，含 RAW 全家）
IMAGE_EXTS = {"jpg", "jpeg", "png", "webp", "gif", "bmp", "tif", "tiff",
              "heic", "heif", "avif",
              "cr2", "cr3", "nef", "arw", "dng", "orf", "rw2", "raf",
              "pef", "srw", "x3f", "3fr", "iiq"}
VIDEO_EXTS = {"mp4", "mov", "m4v", "mkv", "avi", "3gp", "webm", "ts", "mpg", "mpeg"}
AUDIO_EXTS = {"wav", "mp3", "m4a", "aac", "flac", "ogg", "amr"}
ALLOWED_EXTS = IMAGE_EXTS | VIDEO_EXTS | AUDIO_EXTS

# SFace 同人 cosine 阈值：增量归入既有人物用保守值，全局重聚用灵敏值
FACE_ASSIGN_THR = 0.45
FACE_LINK_THR = 0.40

for d in (DATA_DIR, ORIG_DIR, THUMB_DIR, AVATAR_DIR):
    d.mkdir(parents=True, exist_ok=True)
