"""人脸检测 + 特征 + 聚类。

模型（OpenCV Zoo，离线本地推理）：
- YuNet  人脸检测      models/face_detection_yunet_2023mar.onnx
- SFace  人脸特征 128d models/face_recognition_sface_2021dec.onnx

模型缺失时本模块自动禁用（照片仍可上传浏览，只是没有"按脸"）。
聚类：上传时增量归入最相似人物；管理端可全量 Chinese-Whispers 重聚。
"""
import io
import threading
from pathlib import Path

import cv2
import numpy as np
from PIL import Image

from . import config, db, thumbs

_lock = threading.Lock()
_detector = None
_recognizer = None
FAILED = False

YUNET_URL = "https://github.com/opencv/opencv_zoo/raw/main/models/face_detection_yunet/face_detection_yunet_2023mar.onnx"
SFACE_URL = "https://github.com/opencv/opencv_zoo/raw/main/models/face_recognition_sface/face_recognition_sface_2021dec.onnx"


def available() -> bool:
    return (config.MODEL_DIR / "yunet.onnx").exists() and \
           (config.MODEL_DIR / "sface.onnx").exists()


def _load():
    global _detector, _recognizer, FAILED
    with _lock:
        if _detector is not None or FAILED:
            return
        if not available():
            FAILED = True
            return
        yunet = config.MODEL_DIR / "yunet.onnx"
        sface = config.MODEL_DIR / "sface.onnx"
        try:
            _detector = cv2.FaceDetectorYN.create(
                str(yunet), "", (320, 320), score_threshold=0.6)
            _recognizer = cv2.FaceRecognizerSF.create(str(sface), "")
        except Exception:
            # Windows 上 OpenCV dnn 读不了含非 ASCII 字符的路径，拷到临时目录再试
            import shutil
            import tempfile
            tdir = Path(tempfile.gettempdir()) / "tuantu_models"
            tdir.mkdir(exist_ok=True)
            try:
                shutil.copy(yunet, tdir / "yunet.onnx")
                shutil.copy(sface, tdir / "sface.onnx")
                _detector = cv2.FaceDetectorYN.create(
                    str(tdir / "yunet.onnx"), "", (320, 320), score_threshold=0.6)
                _recognizer = cv2.FaceRecognizerSF.create(str(tdir / "sface.onnx"), "")
            except Exception as e:
                FAILED = True
                print(f"[tuantu] 人脸模型加载失败，按脸功能停用: {e!r}")


def detect_and_embed(img_rgb: np.ndarray) -> list[tuple[tuple[int, int, int, int], np.ndarray]]:
    """输入 RGB ndarray，返回 [((x,y,w,h), embedding128), ...]，坐标为输入图像坐标系。"""
    _load()
    if _detector is None:
        return []
    h, w = img_rgb.shape[:2]
    scale = 480.0 / max(h, w)
    if scale < 1:
        img = cv2.resize(img_rgb, (int(w * scale), int(h * scale)))
    else:
        img = img_rgb
    bgr = cv2.cvtColor(img, cv2.COLOR_RGB2BGR)
    _detector.setInputSize((bgr.shape[1], bgr.shape[0]))
    _, faces = _detector.detect(bgr)
    out = []
    if faces is None:
        return out
    for f in faces[:15]:  # 单张最多 15 张脸，防误检爆炸
        x, y, fw, fh = [int(v / scale) for v in f[:4]]  # 映射回原图坐标
        if fw < 40 or fh < 40:  # 太小的脸识别质量差，跳过
            continue
        aligned = _recognizer.alignCrop(bgr, f.reshape(1, -1))
        emb = _recognizer.feature(aligned).flatten()
        if emb.size != 128:
            continue
        out.append(((x, y, fw, fh), emb.astype(np.float32)))
    return out


def _cos(a: np.ndarray, b: np.ndarray) -> float:
    d = float(np.dot(a, b) / ((np.linalg.norm(a) * np.linalg.norm(b)) or 1e-9))
    return max(-1.0, min(1.0, d))


def analyze_asset(asset_id: int):
    """后台任务：对单个 asset 做人脸分析并入聚类。"""
    row = db.q("SELECT * FROM assets WHERE id=?", (asset_id,), one=True)
    if row is None or row["analyzed"]:
        return
    path = config.ORIG_DIR / f"{asset_id}.{row['ext']}"
    if not path.exists():
        db.exec("UPDATE assets SET analyzed=1 WHERE id=?", (asset_id,))
        return
    img = None
    if thumbs.classify(row["ext"]) == "image":
        img = thumbs.decode_for_faces(path, row["ext"])
    else:  # 视频抽 3 帧找脸
        img = _video_frames(path)
    n_faces = 0
    if img is not None:
        frames = img if isinstance(img, list) else [img]
        for frame in frames:
            arr = np.asarray(frame)
            for bbox, emb in detect_and_embed(arr):
                x, y, fw, fh = bbox
                db.exec(
                    "INSERT INTO faces(asset_id,x,y,w,h,embedding) VALUES(?,?,?,?,?,?)",
                    (asset_id, x, y, fw, fh, emb.tobytes()))
                n_faces += 1
                _assign_to_person(emb)
    db.exec("UPDATE assets SET analyzed=1 WHERE id=?", (asset_id,))


def _video_frames(path, n=3):
    if not thumbs.FFMPEG:
        return None
    import subprocess
    frames = []
    for ss in ("1", "3", "0"):
        try:
            r = subprocess.run(
                [thumbs.FFMPEG, "-loglevel", "error", "-ss", ss, "-i", str(path),
                 "-vframes", "1", "-f", "image2pipe", "-vcodec", "png", "-"],
                capture_output=True, timeout=120)
            if r.returncode == 0 and r.stdout:
                frames.append(Image.open(io.BytesIO(r.stdout)).convert("RGB"))
        except Exception:
            continue
        if len(frames) >= n:
            break
    return frames or None


def _assign_to_person(emb: np.ndarray):
    """增量：与每个既有人物的均值比相似度，过阈值并入，否则自立门户。"""
    rows = db.q("SELECT id, mean_emb FROM persons")
    best_pid, best_sim = None, -1.0
    for r in rows:
        sim = _cos(emb, np.frombuffer(r["mean_emb"], np.float32))
        if sim > best_sim:
            best_pid, best_sim = r["id"], sim
    if best_pid is not None and best_sim >= config.FACE_ASSIGN_THR:
        pid = best_pid
        old = np.frombuffer(db.q("SELECT mean_emb FROM persons WHERE id=?", (pid,), one=True)["mean_emb"], np.float32)
        cnt = db.q("SELECT COUNT(*) c FROM faces WHERE person_id=?", (pid,), one=True)["c"]
        mean = ((old * cnt + emb) / (cnt + 1)).astype(np.float32)
        db.exec("UPDATE persons SET mean_emb=? WHERE id=?", (mean.tobytes(), pid))
    else:
        pid = db.exec("INSERT INTO persons(mean_emb, created_at) VALUES(?,?)",
                      (emb.tobytes(), db.now()))
    db.exec("UPDATE faces SET person_id=? WHERE rowid=(SELECT MAX(rowid) FROM faces)", (pid,))


def recluster_all():
    """全量重聚：Chinese-Whispers 图聚类，然后重建 persons。"""
    rows = db.q("SELECT id, embedding FROM faces")
    embs, ids = [], []
    for r in rows:
        ids.append(r["id"])
        embs.append(np.frombuffer(r["embedding"], np.float32))
    if not ids:
        return 0
    X = np.stack(embs)
    Xn = X / (np.linalg.norm(X, axis=1, keepdims=True) + 1e-9)
    n = len(ids)
    sims = Xn @ Xn.T  # 归一化后内积即 cosine
    labels = list(range(n))
    neighbors = [np.where(sims[i] >= config.FACE_LINK_THR)[0].tolist() for i in range(n)]
    import random
    for _ in range(15):
        order = list(range(n))
        random.shuffle(order)
        changed = False
        for i in order:
            counts: dict[int, int] = {}
            for j in neighbors[i]:
                if j != i:
                    counts[labels[j]] = counts.get(labels[j], 0) + 1
            if not counts:
                continue
            best = max(counts.items(), key=lambda kv: kv[1])[0]
            if best != labels[i]:
                labels[i] = best
                changed = True
        if not changed:
            break
    # 重建 persons
    db.exec("UPDATE faces SET person_id=NULL")
    db.exec("DELETE FROM persons")
    mapping: dict[int, int] = {}
    for lab in sorted(set(labels), key=lambda l: -labels.count(l)):
        pid = db.exec("INSERT INTO persons(mean_emb, created_at) VALUES(?,?)",
                      (b"", db.now()))
        mapping[lab] = pid
    for i, lab in enumerate(labels):
        db.exec("UPDATE faces SET person_id=? WHERE id=?", (mapping[lab], ids[i]))
    for lab, pid in mapping.items():
        idx = [i for i, l in enumerate(labels) if l == lab]
        mean = X[idx].mean(axis=0).astype(np.float32)
        db.exec("UPDATE persons SET mean_emb=? WHERE id=?", (mean.tobytes(), pid))
    return len(mapping)


def recluster_mean(pid: int):
    """合并人物后重算某人均值嵌入。"""
    rows = db.q("SELECT embedding FROM faces WHERE person_id=?", (pid,))
    if not rows:
        return
    X = np.stack([np.frombuffer(r["embedding"], np.float32) for r in rows])
    mean = X.mean(axis=0).astype(np.float32)
    db.exec("UPDATE persons SET mean_emb=? WHERE id=?", (mean.tobytes(), pid))
