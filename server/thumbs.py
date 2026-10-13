"""媒体处理：缩略图生成、EXIF 提取。

能力矩阵：
- 常规图片（jpg/png/webp/gif/bmp/tif/avif）: Pillow
- HEIC/HEIF（iPhone 原生格式）            : pillow-heif
- RAW（cr2/cr3/nef/arw/dng...）           : exiftool 抽内嵌预览，抽不到给占位图
- 视频                                    : ffmpeg 抽帧；抽不到给占位图
- 音频                                    : 占位图

exiftool / ffmpeg 缺失时对应能力自动降级，服务照常可跑。
"""
import io
import json
import shutil
import subprocess
from datetime import datetime, timezone

from PIL import Image, ImageDraw
try:
    from pillow_heif import register_heif_opener
    register_heif_opener()
    HAS_HEIF = True
except Exception:
    HAS_HEIF = False

from . import config

Image.MAX_IMAGE_PIXELS = 300_000_000  # 百兆像素全景图也放行

EXIFTOOL = shutil.which("exiftool")
FFMPEG = shutil.which("ffmpeg") or shutil.which("ffmpeg.exe")

_PLACEHOLDER_COLORS = {"video": (66, 103, 178), "audio": (56, 142, 60), "raw": (121, 85, 72)}


def _placeholder(kind: str) -> Image.Image:
    img = Image.new("RGB", (config.THUMB_SIZE, int(config.THUMB_SIZE * 0.75)),
                    _PLACEHOLDER_COLORS.get(kind, (90, 90, 90)))
    d = ImageDraw.Draw(img)
    text = {"video": "VIDEO", "audio": "AUDIO", "raw": "RAW"}.get(kind, "?")
    d.text((img.width / 2, img.height / 2), text, fill="white", anchor="mm")
    return img


def _exiftool_json(path) -> dict:
    if not EXIFTOOL:
        return {}
    try:
        out = subprocess.run([EXIFTOOL, "-j", "-n", str(path)], capture_output=True, timeout=60)
        arr = json.loads(out.stdout.decode("utf-8", "ignore"))
        return arr[0] if arr else {}
    except Exception:
        return {}


def _exiftool_preview(path) -> bytes | None:
    """RAW 内嵌预览，优先全尺寸 JpgFromRaw，其次 PreviewImage、ThumbnailImage。"""
    if not EXIFTOOL:
        return None
    for tag in ("JpgFromRaw", "PreviewImage", "ThumbnailImage"):
        try:
            out = subprocess.run([EXIFTOOL, "-b", f"-{tag}", str(path)],
                                 capture_output=True, timeout=120)
            data = out.stdout
            if out.returncode == 0 and len(data) > 2000 and data[:2] == b"\xff\xd8":
                return data
        except Exception:
            continue
    return None


def _parse_ts(meta: dict) -> float | None:
    """exiftool JSON 里挑拍摄时间字段，epoch 数字或 '2026:09:09 10:00:00' 类字符串。"""
    for key in ("DateTimeOriginal", "CreateDate", "MediaCreateDate", "TrackCreateDate",
                "DateTime", "FileModifyDate"):
        v = meta.get(key)
        if not v:
            continue
        if isinstance(v, (int, float)):
            return float(v)
        s = str(v).strip()
        # 去掉时区尾巴（+08:00 / +0800）
        for tail in ("+08:00", "+0800", "Z"):
            if s.endswith(tail):
                s = s[: -len(tail)].strip()
                break
        for fmt in ("%Y:%m:%d %H:%M:%S", "%Y-%m-%d %H:%M:%S", "%Y-%m-%dT%H:%M:%S",
                    "%Y-%m-%d %H:%M:%S.%f"):
            try:
                dt = datetime.strptime(s, fmt)
                return dt.replace(tzinfo=timezone.utc).timestamp()
            except ValueError:
                continue
        try:
            return datetime.fromisoformat(s).replace(tzinfo=timezone.utc).timestamp()
        except ValueError:
            continue
    return None


def probe(path, ext: str) -> dict:
    """返回 {width,height,duration,taken_at}，尽量从 EXIF 取。"""
    kind = classify(ext)
    meta = _exiftool_json(path)
    out = {
        "width": int(meta["ImageWidth"]) if meta.get("ImageWidth") else None,
        "height": int(meta["ImageHeight"]) if meta.get("ImageHeight") else None,
        "duration": float(meta["Duration"]) if meta.get("Duration") else None,
        "taken_at": _parse_ts(meta),
    }
    if kind == "image" and (not out["width"] or not out["taken_at"]):
        try:
            with Image.open(path) as im:
                out["width"] = out["width"] or im.width
                out["height"] = out["height"] or im.height
            if not out["taken_at"]:
                out["taken_at"] = _pillow_exif_time(path)
        except Exception:
            pass
    return out


def _pillow_exif_time(path) -> float | None:
    try:
        import exifread
        with open(path, "rb") as f:
            tags = exifread.process_file(f, details=False, stop_tag="DateTimeOriginal")
        v = tags.get("EXIF DateTimeOriginal") or tags.get("Image DateTime")
        if v:
            dt = datetime.strptime(str(v), "%Y:%m:%d %H:%M:%S")
            return dt.replace(tzinfo=timezone.utc).timestamp()
    except Exception:
        pass
    return None


def classify(ext: str) -> str:
    if ext in config.VIDEO_EXTS:
        return "video"
    if ext in config.AUDIO_EXTS:
        return "audio"
    return "image"


def is_raw(ext: str) -> bool:
    return ext in {"cr2", "cr3", "nef", "arw", "dng", "orf", "rw2", "raf",
                   "pef", "srw", "x3f", "3fr", "iiq"}


def make_thumb(path, ext: str, out_path) -> bool:
    """生成缩略图，成功返回 True。"""
    kind = classify(ext)
    try:
        if kind == "image":
            src = None
            if is_raw(ext):
                prev = _exiftool_preview(path)
                if prev:
                    src = Image.open(io.BytesIO(prev))
            else:
                src = Image.open(path)
                if ext in ("heic", "heif") and not HAS_HEIF:
                    src = None
            if src is None:
                src = _placeholder("raw" if is_raw(ext) else kind)
            with src:
                src = src.convert("RGB")
                src.thumbnail((config.THUMB_SIZE, config.THUMB_SIZE), Image.LANCZOS)
                src.save(out_path, "WEBP", quality=82)
                return True
        if kind == "video":
            if FFMPEG:
                for ss in (config.VIDEO_FRAME_AT, 0.0, None):
                    cmd = [FFMPEG, "-y", "-loglevel", "error"]
                    if ss is not None:
                        cmd += ["-ss", str(ss)]
                    cmd += ["-i", str(path), "-vframes", "1", "-vf",
                            f"scale='min({config.THUMB_SIZE},iw)':-2", str(out_path)]
                    try:
                        r = subprocess.run(cmd, capture_output=True, timeout=120)
                        if r.returncode == 0 and out_path.exists() and out_path.stat().st_size > 500:
                            img = Image.open(out_path).convert("RGB")
                            img.save(out_path, "WEBP", quality=82)
                            return True
                    except Exception:
                        continue
            ph = _placeholder("video")
            ph.save(out_path, "WEBP", quality=82)
            return True
        # 音频
        _placeholder("audio").save(out_path, "WEBP", quality=82)
        return True
    except Exception:
        return False


def decode_for_faces(path, ext: str):
    """给人脸分析一个可解码的 RGB 图。RAW 用内嵌预览，解不出返回 None。"""
    kind = classify(ext)
    if kind != "image":
        return None
    try:
        if is_raw(ext):
            prev = _exiftool_preview(path)
            return Image.open(io.BytesIO(prev)).convert("RGB") if prev else None
        return Image.open(path).convert("RGB")
    except Exception:
        return None
