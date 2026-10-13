"""团图 Tuantu — 离线旅行共享相册服务。

启动: uvicorn server.main:app --host 0.0.0.0 --port 8000
"""
import hashlib
import io
import os
import queue
import socket
import threading
import time
import uuid
import zipfile
from contextlib import asynccontextmanager
from datetime import datetime, timezone
from pathlib import Path

from fastapi import Body, Depends, FastAPI, File, HTTPException, Request, UploadFile
from fastapi.responses import FileResponse, JSONResponse, StreamingResponse
from fastapi.staticfiles import StaticFiles
from PIL import Image
from starlette.background import BackgroundTask

from . import config, db, faces, thumbs

db.init()


def _local_ips() -> list[str]:
    ips: set[str] = set()
    try:
        for info in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET):
            ip = info[4][0]
            if not ip.startswith("127."):
                ips.add(ip)
    except Exception:
        pass
    return sorted(ips)


_zc = None


def _register_mdns():
    global _zc
    try:
        from zeroconf import ServiceInfo, Zeroconf
        _zc = Zeroconf()
        info = ServiceInfo(
            "_tuantu._tcp.local.",
            "团图盒子._tuantu._tcp.local.",
            port=config.PORT,
            server="tuantu.local.",
            properties={"scheme": "https", "path": "/"},
        )
        _zc.register_service(info)
        print("[tuantu] mDNS 广播已启动 tuantu.local:%d" % config.PORT)
    except Exception as e:
        print(f"[tuantu] mDNS 不可用（不影响手动输入地址）: {e!r}")


@asynccontextmanager
async def lifespan(_):
    """在局域网里广播 _tuantu._tcp 服务，Flutter 客户端靠它自动发现盒子。

    zeroconf 的阻塞注册必须放在自己的线程里（uvicorn 的事件循环不允许阻塞）。
    """
    threading.Thread(target=_register_mdns, daemon=True).start()
    yield


app = FastAPI(title="团图 Tuantu", docs_url=None, redoc_url=None,
              lifespan=lifespan)

# ---------------------------------------------------------------- 基础设施

_thumb_q: queue.Queue = queue.Queue()
_face_q: queue.Queue = queue.Queue()
_FAST_THUMB = {"jpg", "jpeg", "png", "webp", "gif", "bmp"}


def _fill_meta(asset_id: int, path: Path, ext: str):
    meta = thumbs.probe(path, ext)
    db.exec(
        "UPDATE assets SET width=COALESCE(?, width), height=COALESCE(?, height),"
        " duration=COALESCE(?, duration), taken_at=COALESCE(?, taken_at) WHERE id=?",
        (meta.get("width"), meta.get("height"), meta.get("duration"),
         meta.get("taken_at"), asset_id))


def _ensure_thumb(asset_id: int, ext: str) -> None:
    path = config.ORIG_DIR / f"{asset_id}.{ext}"
    out = config.THUMB_DIR / f"{asset_id}.webp"
    if not out.exists() or out.stat().st_size < 32:
        if thumbs.make_thumb(path, ext, out):
            db.exec("UPDATE assets SET has_thumb=1 WHERE id=?", (asset_id,))
    else:
        row = db.q("SELECT has_thumb FROM assets WHERE id=?", (asset_id,), one=True)
        if row and not row["has_thumb"]:
            db.exec("UPDATE assets SET has_thumb=1 WHERE id=?", (asset_id,))
    _fill_meta(asset_id, path, ext)


def _thumb_worker():
    """缩略图单独排队：人脸分析再慢，新上传也能马上出图。"""
    while True:
        asset_id = _thumb_q.get()
        try:
            row = db.q("SELECT ext FROM assets WHERE id=?", (asset_id,), one=True)
            if row:
                _ensure_thumb(asset_id, row["ext"])
                _face_q.put(asset_id)
        except Exception as e:
            print(f"[tuantu] asset {asset_id} 缩略图失败: {e!r}")
            try:
                _face_q.put(asset_id)
            except Exception:
                pass
        finally:
            _thumb_q.task_done()


def _face_worker():
    while True:
        asset_id = _face_q.get()
        try:
            faces.analyze_asset(asset_id)
        except Exception as e:
            try:
                db.exec("UPDATE assets SET analyzed=1 WHERE id=?", (asset_id,))
            except Exception:
                pass
            print(f"[tuantu] asset {asset_id} 人脸分析失败: {e!r}")
        finally:
            _face_q.task_done()


threading.Thread(target=_thumb_worker, daemon=True, name="tuantu-thumb").start()
threading.Thread(target=_face_worker, daemon=True, name="tuantu-face").start()


def current_user(request: Request):
    token = request.cookies.get("tt_token") or request.headers.get("X-Token", "")
    if token:
        u = user_by_token(token)
        if u:
            return u
    raise HTTPException(401, "请先加入")


def require_admin(request: Request):
    if request.headers.get("X-Admin-Token", "") != config.ADMIN_CODE:
        raise HTTPException(401, "管理口令错误")


def user_by_token(token: str):
    return db.q("SELECT * FROM users WHERE token=?", (token,), one=True)


def _user_avatar(u) -> str | None:
    if not u:
        return None
    try:
        v = int(u["avatar"] or 0)
    except (KeyError, TypeError, ValueError):
        v = 0
    if not v:
        return None
    return f"/api/user/{u['id']}/avatar?v={v}"


def _card(a, user) -> dict:
    liked = db.q("SELECT 1 x FROM likes WHERE asset_id=? AND user_id=?",
                 (a["id"], user["id"]), one=True) is not None
    likes = db.q("SELECT COUNT(*) c FROM likes WHERE asset_id=?",
                 (a["id"],), one=True)["c"]
    comments = db.q("SELECT COUNT(*) c FROM comments WHERE asset_id=?",
                    (a["id"],), one=True)["c"]
    uploader = db.q("SELECT id, name, avatar FROM users WHERE id=?",
                    (a["uploader_id"],), one=True)
    return {
        "id": a["id"], "thumb": f"/api/asset/{a['id']}/thumb",
        "kind": a["kind"], "ext": a["ext"], "has_thumb": a["has_thumb"],
        "orig_name": a["orig_name"],
        "width": a["width"], "height": a["height"], "duration": a["duration"],
        "taken_at": a["taken_at"], "created_at": a["created_at"],
        "uploader": uploader["name"] if uploader else "?",
        "uploader_id": a["uploader_id"],
        "avatar": _user_avatar(uploader),
        "mine": bool(a["uploader_id"] == user["id"]),
        "likes": likes, "liked": liked, "comments": comments,
    }


def _claim_person_ids(user) -> list[int]:
    rows = db.q("SELECT person_id id FROM person_claims WHERE user_id=?", (user["id"],))
    return [r["id"] for r in rows]


# ---------------------------------------------------------------- 加入 / 会话

@app.post("/api/join")
def join(body: dict):
    name = (body.get("name") or "").strip()[:20]
    device_id = (body.get("device_id") or "").strip()[:200]
    code = (body.get("code") or "").strip()
    if config.ROOM_CODE and code != config.ROOM_CODE:
        raise HTTPException(403, "口令不对，问问团长")
    if not name:
        raise HTTPException(400, "先给自己起个名字")
    if device_id:
        u = db.q("SELECT * FROM users WHERE device_id=?", (device_id,), one=True)
        if not u:
            # 首次升级让设备接管同名旧账号，保留历史作品和评论。
            u = db.q("""SELECT * FROM users
                      WHERE device_id IS NULL AND name=? ORDER BY id LIMIT 1""",
                     (name,), one=True)
            if u:
                db.exec("UPDATE users SET device_id=? WHERE id=?", (device_id, u["id"]))
        if u:
            token = u["token"]
            name = u["name"]
        else:
            token = db.new_token()
            db.exec("""INSERT INTO users(name, device_id, token, created_at)
                     VALUES(?,?,?,?)""", (name, device_id, token, db.now()))
    else:
        # 兼容还未升级的客户端；新客户端永远发送 device_id。
        u = db.q("""SELECT * FROM users
                  WHERE device_id IS NULL AND name=? ORDER BY id LIMIT 1""",
                 (name,), one=True)
        if u:
            token = u["token"]
        else:
            token = db.new_token()
            db.exec("INSERT INTO users(name, token, created_at) VALUES(?,?,?)",
                    (name, token, db.now()))
    resp = JSONResponse({"ok": True, "name": name, "token": token})
    resp.set_cookie("tt_token", token, max_age=60 * 60 * 24 * 90,
                    samesite="lax", httponly=True)
    return resp


@app.get("/api/me")
def me(user=Depends(current_user)):
    uploaded = db.q("SELECT COUNT(*) c FROM assets WHERE uploader_id=?",
                    (user["id"],), one=True)["c"]
    kept = db.q("SELECT COUNT(*) c FROM decisions WHERE user_id=? AND action='keep'",
                (user["id"],), one=True)["c"]
    last = db.q("SELECT MAX(created_at) t FROM assets WHERE uploader_id=?",
                (user["id"],), one=True)
    return {"id": user["id"], "name": user["name"], "uploaded": uploaded, "kept": kept,
            "claimed": _claim_person_ids(user),
            "faces_ready": faces.available(),
            "last_upload": last["t"] if last else None,
            "avatar": _user_avatar(user)}


def _epoch_day(ts) -> str | None:
    if not ts:
        return None
    try:
        d = datetime.fromtimestamp(float(ts), tz=timezone.utc)
    except (TypeError, ValueError, OSError):
        return None
    return f"{d.year:04d}-{d.month:02d}-{d.day:02d}"


@app.get("/api/me/upload_index")
def upload_index(user=Depends(current_user)):
    rows = db.q("SELECT orig_name, taken_at, created_at FROM assets WHERE uploader_id=?",
                (user["id"],))
    items = []
    for r in rows:
        day = _epoch_day(r["taken_at"]) or _epoch_day(r["created_at"])
        if not day:
            continue
        items.append({"name": r["orig_name"], "day": day})
    return {"items": items}


@app.post("/api/me/profile")
def update_profile(body: dict = Body(...), user=Depends(current_user)):
    name = (body.get("name") or "").strip()[:20]
    if not name:
        raise HTTPException(400, "名字不能为空")
    if name != user["name"]:
        db.exec("UPDATE users SET name=? WHERE id=?", (name, user["id"]))
    return {"ok": True, "name": name, "id": user["id"]}


def _save_avatar(user_id: int, data: bytes) -> int:
    img = None
    try:
        with Image.open(io.BytesIO(data)) as src:
            img = src.convert("RGB")
    except Exception:
        img = None
    if img is None:
        tmp = config.AVATAR_DIR / f"_in_{user_id}.bin"
        tmp.write_bytes(data)
        try:
            for ext in ("jpg", "jpeg", "png", "webp", "heic", "heif"):
                img = thumbs.decode_for_faces(tmp, ext)
                if img is not None:
                    break
        finally:
            tmp.unlink(missing_ok=True)
    if img is None:
        raise HTTPException(400, "不支持的图片，请换一张 JPG / PNG")
    w, h = img.size
    if w <= 0 or h <= 0:
        raise HTTPException(400, "图片打不开")
    side = min(w, h)
    img = img.crop(((w - side) // 2, (h - side) // 2,
                    (w - side) // 2 + side, (h - side) // 2 + side))
    img.thumbnail((480, 480), Image.LANCZOS)
    dest = config.AVATAR_DIR / f"{user_id}.webp"
    img.save(dest, "WEBP", quality=85)
    stamp = int(db.now())
    db.exec("UPDATE users SET avatar=? WHERE id=?", (stamp, user_id))
    return stamp


@app.post("/api/me/avatar")
async def update_avatar(file: UploadFile = File(...), user=Depends(current_user)):
    data = await file.read()
    if not data:
        raise HTTPException(400, "空文件")
    if len(data) > 12 * 1024 * 1024:
        raise HTTPException(400, "头像太大了")
    try:
        stamp = _save_avatar(user["id"], data)
    except HTTPException:
        raise
    except Exception:
        raise HTTPException(400, "不支持的图片")
    return {"ok": True, "avatar": f"/api/user/{user['id']}/avatar?v={stamp}"}


@app.get("/api/user/{uid}/avatar")
def user_avatar(uid: int):
    p = config.AVATAR_DIR / f"{uid}.webp"
    if not p.exists():
        raise HTTPException(404)
    return FileResponse(p, media_type="image/webp",
                        headers={"Cache-Control": "max-age=86400"})


@app.get("/api/status")
def status():
    # 连接发现是生命线：这里只读内存，绝不等待正在上传/识别的 SQLite。
    return dict(_status_cache)


_status_cache = {"service": "tuantu", "protocol": 1, "total": 0,
                 "pending": 0, "persons": 0, "faces_ready": False}


def _status_cache_worker():
    global _status_cache
    while True:
        try:
            total = db.q("SELECT COUNT(*) c FROM assets", one=True)["c"]
            analyzed = db.q(
                "SELECT COUNT(*) c FROM assets WHERE analyzed=1", one=True)["c"]
            _status_cache = {
                "service": "tuantu", "protocol": 1,
                "total": total, "pending": total - analyzed,
                "persons": db.q("SELECT COUNT(*) c FROM persons", one=True)["c"],
                "faces_ready": faces.available(),
            }
        except Exception:
            pass
        time.sleep(2)


threading.Thread(target=_status_cache_worker, daemon=True,
                 name="tuantu-status").start()


# ---------------------------------------------------------------- 上传

@app.post("/api/upload")
async def upload(files: list[UploadFile] = File(...), user=Depends(current_user)):
    accepted, duplicates, rejected = [], [], []
    for f in files:
        ext = Path(f.filename or "").suffix.lstrip(".").lower()
        if ext not in config.ALLOWED_EXTS:
            rejected.append(f"{f.filename}（.{ext or '无扩展名'} 不支持）")
            continue
        sha = hashlib.sha256()
        tmp = config.ORIG_DIR / f"_tmp_{uuid.uuid4().hex}"
        size = 0
        try:
            with open(tmp, "wb") as out:
                while chunk := await f.read(1024 * 1024):
                    sha.update(chunk)
                    size += len(chunk)
                    out.write(chunk)
            if size == 0:
                rejected.append(f.filename)
                continue
            dup = db.q("SELECT id FROM assets WHERE sha256=? LIMIT 1",
                       (sha.hexdigest(),), one=True)
            if dup:
                duplicates.append({"name": f.filename, "from": _uploader_name(dup["id"])})
                continue
            aid = db.exec(
                "INSERT INTO assets(uploader_id, sha256, orig_name, ext, kind, size,"
                " created_at) VALUES(?,?,?,?,?,?,?)",
                (user["id"], sha.hexdigest(), f.filename, ext,
                 thumbs.classify(ext), size, db.now()))
            dest = config.ORIG_DIR / f"{aid}.{ext}"
            try:
                os.replace(tmp, dest)
            except Exception:
                try:
                    db.exec("DELETE FROM assets WHERE id=?", (aid,))
                except Exception:
                    pass
                raise
            if ext in _FAST_THUMB:
                try:
                    _ensure_thumb(aid, ext)
                except Exception as e:
                    print(f"[tuantu] 即时缩略图失败 {aid}: {e!r}")
            _thumb_q.put(aid)
            accepted.append({"id": aid, "name": f.filename})
        finally:
            tmp.unlink(missing_ok=True)
    return {"accepted": accepted, "duplicates": duplicates, "rejected": rejected}


def _uploader_name(asset_id: int) -> str:
    r = db.q("""SELECT u.name n FROM assets a JOIN users u ON u.id=a.uploader_id
                WHERE a.id=?""", (asset_id,), one=True)
    return r["n"] if r else "?"


# ---------------------------------------------------------------- 发牌（滑动选片）

def _deal_pool(view: str, user):
    base = """SELECT a.* FROM assets a
              WHERE NOT EXISTS(SELECT 1 FROM decisions d
                               WHERE d.asset_id=a.id AND d.user_id=? AND d.view=?)"""
    args = [user["id"], view]
    if view.startswith("person:"):
        pid = int(view.split(":", 1)[1])
        base += " AND EXISTS(SELECT 1 FROM faces f WHERE f.asset_id=a.id AND f.person_id=?)"
        args.append(pid)
    elif view == "mine":
        base += """ AND EXISTS(SELECT 1 FROM faces f JOIN person_claims c
                               ON c.person_id=f.person_id
                               WHERE f.asset_id=a.id AND c.user_id=?)"""
        args.append(user["id"])
    if view == "random":
        base += " ORDER BY RANDOM()"
    else:  # timeline / mine / person:* 按拍摄时间正序讲故事
        base += " ORDER BY COALESCE(a.taken_at, a.created_at) ASC, a.id ASC"
    return db.q(base, args)


@app.get("/api/deal")
def deal(view: str = "timeline", user=Depends(current_user)):
    pool = _deal_pool(view, user)
    seen = db.q("SELECT COUNT(*) c FROM decisions WHERE user_id=? AND view=?",
                (user["id"], view), one=True)["c"]
    batch_no = seen // config.BATCH_SIZE + 1
    cards = [_card(a, user) for a in pool[: config.BATCH_SIZE]]
    return {"batch_no": batch_no, "cards": cards, "view": view,
            "remaining": max(0, len(pool) - len(cards))}


@app.post("/api/decide")
def decide(body: dict, user=Depends(current_user)):
    aid, action, batch_no = body.get("asset_id"), body.get("action"), \
        body.get("batch_no", 0)
    view = body.get("view", "timeline")
    if action not in ("keep", "skip") or not aid:
        raise HTTPException(400, "参数不对")
    db.exec("""INSERT INTO decisions(user_id, asset_id, view, action, batch_no, created_at)
               VALUES(?,?,?,?,?,?)
               ON CONFLICT(user_id, asset_id, view) DO UPDATE SET action=excluded.action,
                 batch_no=excluded.batch_no, created_at=excluded.created_at""",
            (user["id"], aid, view, action, batch_no, db.now()))
    return {"ok": True}


@app.post("/api/like")
def like(body: dict, user=Depends(current_user)):
    aid = body.get("asset_id")
    if not aid:
        raise HTTPException(400, "缺 asset_id")
    has = db.q("SELECT 1 x FROM likes WHERE asset_id=? AND user_id=?",
               (aid, user["id"]), one=True)
    if has:
        db.exec("DELETE FROM likes WHERE asset_id=? AND user_id=?", (aid, user["id"]))
        liked = False
    else:
        db.exec("INSERT INTO likes(asset_id, user_id, created_at) VALUES(?,?,?)",
                (aid, user["id"], db.now()))
        liked = True
    n = db.q("SELECT COUNT(*) c FROM likes WHERE asset_id=?", (aid,), one=True)["c"]
    return {"liked": liked, "likes": n}


def _comment_row(r, user) -> dict:
    return {
        "id": r["id"], "body": r["body"], "name": r["name"],
        "created_at": r["created_at"], "mine": r["user_id"] == user["id"],
    }


@app.get("/api/asset/{asset_id}/comments")
def list_comments(asset_id: int, user=Depends(current_user)):
    if not db.q("SELECT 1 x FROM assets WHERE id=?", (asset_id,), one=True):
        raise HTTPException(404)
    rows = db.q("""SELECT c.id, c.body, c.created_at, c.user_id, u.name
                   FROM comments c JOIN users u ON u.id=c.user_id
                   WHERE c.asset_id=? ORDER BY c.created_at ASC, c.id ASC""",
                (asset_id,))
    return {"comments": [_comment_row(r, user) for r in rows]}


@app.post("/api/asset/{asset_id}/comments")
def add_comment(asset_id: int, body: dict, user=Depends(current_user)):
    if not db.q("SELECT 1 x FROM assets WHERE id=?", (asset_id,), one=True):
        raise HTTPException(404)
    text = (body.get("body") or "").strip()[:500]
    if not text:
        raise HTTPException(400, "写点什么再发")
    now = db.now()
    cid = db.exec(
        "INSERT INTO comments(asset_id, user_id, body, created_at) VALUES(?,?,?,?)",
        (asset_id, user["id"], text, now))
    return {"id": cid, "body": text, "name": user["name"],
            "created_at": now, "mine": True}


@app.post("/api/batch/{batch_no}/confirm")
def confirm_batch(batch_no: int, view: str = "timeline",
                  user=Depends(current_user)):
    n = db.q("""SELECT COUNT(*) c FROM decisions
                WHERE user_id=? AND batch_no=? AND view=? AND action='keep'""",
             (user["id"], batch_no, view), one=True)["c"]
    return {"keep": n, "url": f"/api/batch/{batch_no}/download?view={view}"}


@app.get("/api/batch/{batch_no}/download")
def download_batch(batch_no: int, view: str = "timeline",
                   user=Depends(current_user)):
    rows = db.q("""SELECT a.id, a.orig_name, a.ext FROM decisions d
                   JOIN assets a ON a.id=d.asset_id
                   WHERE d.user_id=? AND d.batch_no=? AND d.view=? AND d.action='keep'
                   ORDER BY a.id""", (user["id"], batch_no, view))
    if not rows:
        raise HTTPException(404, "这批没有收藏的照片")
    tmp = config.DATA_DIR / f"_dl_batch{batch_no}_u{user['id']}.zip"
    tmp.unlink(missing_ok=True)
    with zipfile.ZipFile(tmp, "w", zipfile.ZIP_STORED, allowZip64=True) as zf:
        used = set()
        for r in rows:
            p = config.ORIG_DIR / f"{r['id']}.{r['ext']}"
            if not p.exists():
                continue
            name = r["orig_name"] or f"{r['id']}.{r['ext']}"
            stem, dot, ext = name.rpartition(".")
            if not dot:
                stem, ext = name, r["ext"]
            i, uniq = 1, name
            while uniq.lower() in used:
                i += 1
                uniq = f"{stem}({i}).{ext}"
            used.add(uniq.lower())
            zf.write(p, arcname=uniq)
    return FileResponse(
        tmp, media_type="application/zip", filename=f"tuantu_batch{batch_no}.zip",
        background=BackgroundTask(lambda: tmp.unlink(missing_ok=True)))


# ---------------------------------------------------------------- 相册浏览

def _list_own_assets(owner, sort: str, offset: int, limit: int, viewer=None) -> dict:
    viewer = viewer or owner
    sql = "SELECT a.* FROM assets a WHERE a.uploader_id=?"
    args: list = [owner["id"]]
    if sort == "likes":
        sql += """ ORDER BY (SELECT COUNT(*) FROM likes l WHERE l.asset_id=a.id) DESC,
                   a.id DESC"""
    elif sort == "comments":
        sql += """ ORDER BY (SELECT COUNT(*) FROM comments c WHERE c.asset_id=a.id) DESC,
                   a.id DESC"""
    else:
        sql += " ORDER BY a.created_at DESC, a.id DESC"
    limit = max(1, min(int(limit), 200))
    offset = max(0, int(offset))
    sql += " LIMIT ? OFFSET ?"
    args.extend([limit, offset])
    rows = db.q(sql, args)
    return {"items": [_card(a, viewer) for a in rows],
            "offset": offset + len(rows), "end": len(rows) < limit}


def _public_profile(u) -> dict:
    uploaded = db.q("SELECT COUNT(*) c FROM assets WHERE uploader_id=?",
                    (u["id"],), one=True)["c"]
    last = db.q("SELECT MAX(created_at) t FROM assets WHERE uploader_id=?",
                (u["id"],), one=True)
    return {
        "id": u["id"], "name": u["name"], "uploaded": uploaded,
        "last_upload": last["t"] if last else None,
        "avatar": _user_avatar(u),
    }


@app.get("/api/user/{uid}")
def user_profile(uid: int, user=Depends(current_user)):
    u = db.q("SELECT * FROM users WHERE id=?", (uid,), one=True)
    if not u:
        raise HTTPException(404, "没有这个人")
    return _public_profile(u)


@app.get("/api/user/{uid}/assets")
def user_assets(uid: int, sort: str = "time", offset: int = 0, limit: int = 90,
                user=Depends(current_user)):
    u = db.q("SELECT * FROM users WHERE id=?", (uid,), one=True)
    if not u:
        raise HTTPException(404, "没有这个人")
    return _list_own_assets(u, sort, offset, limit, viewer=user)


@app.get("/api/me/assets")
def my_assets(sort: str = "time", offset: int = 0, limit: int = 90,
              user=Depends(current_user)):
    """只返回当前登录用户自己上传的作品。"""
    return _list_own_assets(user, sort, offset, limit, viewer=user)


@app.get("/api/gallery")
def gallery(view: str = "all", cursor: float | None = None,
            limit: int = 60, sort: str = "time", offset: int = 0,
            user=Depends(current_user)):
    if view == "uploaded":
        return _list_own_assets(user, sort, offset, limit)
    sql = "SELECT a.* FROM assets a WHERE 1=1"
    args: list = []
    if view.startswith("person:"):
        sql += " AND EXISTS(SELECT 1 FROM faces f WHERE f.asset_id=a.id AND f.person_id=?)"
        args.append(int(view.split(":", 1)[1]))
    elif view in ("mine", "mine_unseen"):
        sql += """ AND EXISTS(SELECT 1 FROM faces f JOIN person_claims c
                              ON c.person_id=f.person_id
                              WHERE f.asset_id=a.id AND c.user_id=?)"""
        args.append(user["id"])
        if view == "mine_unseen":
            sql += """ AND NOT EXISTS(SELECT 1 FROM views v
                                      WHERE v.asset_id=a.id AND v.user_id=?)"""
            args.append(user["id"])
    elif view == "liked":
        sql += " AND EXISTS(SELECT 1 FROM likes l WHERE l.asset_id=a.id AND l.user_id=?)"
        args.append(user["id"])
    elif view == "images":
        sql += " AND a.kind='image'"
    elif view == "videos":
        sql += " AND a.kind='video'"
    elif view == "unseen":
        sql += """ AND NOT EXISTS(SELECT 1 FROM views v
                                  WHERE v.asset_id=a.id AND v.user_id=?)"""
        args.append(user["id"])
    elif view == "hot":
        sql += """ AND (
            (SELECT COUNT(*) FROM likes l WHERE l.asset_id=a.id) >= 1
            OR (SELECT COUNT(*) FROM comments c WHERE c.asset_id=a.id) >= 1
        )"""
    if view == "hot":
        sql += """ ORDER BY (
            (SELECT COUNT(*) FROM likes l WHERE l.asset_id=a.id) +
            (SELECT COUNT(*) FROM comments c WHERE c.asset_id=a.id)
        ) DESC, a.id DESC LIMIT ? OFFSET ?"""
        args.extend([limit, offset])
    else:
        if cursor is not None:
            sql += " AND COALESCE(a.taken_at, a.created_at) < ?"
            args.append(cursor)
        sql += " ORDER BY COALESCE(a.taken_at, a.created_at) DESC, a.id DESC LIMIT ?"
        args.append(limit)
    rows = db.q(sql, args)
    return {"items": [_card(a, user) for a in rows],
            "cursor": (rows[-1]["taken_at"] or rows[-1]["created_at"]) if rows else None}


@app.post("/api/seen")
def mark_seen(body: dict, user=Depends(current_user)):
    aid = body.get("asset_id")
    if not aid:
        raise HTTPException(400, "缺 asset_id")
    db.exec(
        "INSERT OR IGNORE INTO views(user_id, asset_id, created_at) VALUES(?,?,?)",
        (user["id"], int(aid), db.now()))
    return {"ok": True}


@app.delete("/api/asset/{asset_id}")
def delete_asset(asset_id: int, user=Depends(current_user)):
    a = db.q("SELECT * FROM assets WHERE id=?", (asset_id,), one=True)
    if not a:
        raise HTTPException(404, "照片不存在")
    if a["uploader_id"] != user["id"]:
        raise HTTPException(403, "只能删除自己上传的")
    db.exec("DELETE FROM likes WHERE asset_id=?", (asset_id,))
    db.exec("DELETE FROM comments WHERE asset_id=?", (asset_id,))
    db.exec("DELETE FROM decisions WHERE asset_id=?", (asset_id,))
    db.exec("DELETE FROM faces WHERE asset_id=?", (asset_id,))
    db.exec("DELETE FROM assets WHERE id=?", (asset_id,))
    (config.ORIG_DIR / f"{a['id']}.{a['ext']}").unlink(missing_ok=True)
    (config.THUMB_DIR / f"{a['id']}.webp").unlink(missing_ok=True)
    return {"ok": True}


@app.get("/api/asset/{asset_id}/detail")
def asset_detail(asset_id: int, user=Depends(current_user)):
    a = db.q("SELECT * FROM assets WHERE id=?", (asset_id,), one=True)
    if not a:
        raise HTTPException(404)
    card = _card(a, user)
    likes = db.q("""SELECT u.name FROM likes l JOIN users u ON u.id=l.user_id
                    WHERE l.asset_id=? ORDER BY l.created_at""", (asset_id,))
    card["liked_by"] = [r["name"] for r in likes]
    card["orig_name"] = a["orig_name"]
    card["size"] = a["size"]
    card["faces"] = [dict(r) for r in db.q(
        "SELECT id, x, y, w, h, person_id FROM faces WHERE asset_id=?", (asset_id,))]
    return card


# ---------------------------------------------------------------- 人物

@app.get("/api/persons")
def persons(user=Depends(current_user)):
    mine = {r["person_id"] for r in db.q(
        "SELECT person_id FROM person_claims WHERE user_id=?", (user["id"],))}
    rows = db.q("""SELECT p.id, p.name, p.claimed_by,
                   (SELECT COUNT(*) FROM faces f WHERE f.person_id=p.id) n
                   FROM persons p ORDER BY n DESC""")
    out = []
    for r in rows:
        if r["n"] == 0:
            continue
        face = db.q("""SELECT f.id fid, f.asset_id FROM faces f WHERE f.person_id=?
                       ORDER BY (f.w*f.h) DESC LIMIT 1""", (r["id"],), one=True)
        out.append({"id": r["id"], "name": r["name"], "count": r["n"],
                    "cover": f"/api/asset/{face['asset_id']}/face/{face['fid']}"
                    if face else None,
                    "claimed_by_me": r["id"] in mine,
                    "claimed_by": r["claimed_by"]})
    return out


@app.post("/api/persons/{pid}/claim")
def claim(pid: int, user=Depends(current_user)):
    if not db.q("SELECT 1 x FROM persons WHERE id=?", (pid,), one=True):
        raise HTTPException(404)
    db.exec("INSERT OR IGNORE INTO person_claims(person_id, user_id, created_at) VALUES(?,?,?)",
            (pid, user["id"], db.now()))
    return {"ok": True}


@app.post("/api/persons/{pid}/rename")
def rename_person(pid: int, body: dict, user=Depends(current_user)):
    name = (body.get("name") or "").strip()[:20] or None
    if not db.q("SELECT 1 x FROM persons WHERE id=?", (pid,), one=True):
        raise HTTPException(404)
    db.exec("UPDATE persons SET name=? WHERE id=?", (name, pid))
    return {"ok": True}


@app.post("/api/persons/merge")
def merge_persons(body: dict, user=Depends(current_user)):
    ids = []
    for e in body.get("ids") or []:
        try:
            ids.append(int(e))
        except (TypeError, ValueError):
            pass
    ids = list(dict.fromkeys(ids))
    if len(ids) < 2:
        raise HTTPException(400, "至少选两个人物才能合并")
    keep, best = ids[0], -1
    for pid in ids:
        n = db.q("SELECT COUNT(*) c FROM faces WHERE person_id=?", (pid,), one=True)["c"]
        if n > best:
            best, keep = n, pid
    for pid in ids:
        if pid == keep:
            continue
        db.exec("UPDATE faces SET person_id=? WHERE person_id=?", (keep, pid))
        db.exec("""INSERT OR IGNORE INTO person_claims(person_id, user_id, created_at)
                   SELECT ?, user_id, created_at FROM person_claims WHERE person_id=?""",
                (keep, pid))
        db.exec("DELETE FROM person_claims WHERE person_id=?", (pid,))
        db.exec("DELETE FROM persons WHERE id=?", (pid,))
    try:
        faces.recluster_mean(keep)
    except Exception:
        pass
    return {"ok": True, "id": keep}


@app.post("/api/persons/{pid}/unclaim")
def unclaim(pid: int, user=Depends(current_user)):
    db.exec("DELETE FROM person_claims WHERE person_id=? AND user_id=?",
            (pid, user["id"]))
    return {"ok": True}


# ---------------------------------------------------------------- 媒体文件

@app.get("/api/asset/{asset_id}/thumb")
def thumb(asset_id: int):
    p = config.THUMB_DIR / f"{asset_id}.webp"
    if not p.exists():
        raise HTTPException(404)
    return FileResponse(p, media_type="image/webp",
                        headers={"Cache-Control": "max-age=86400"})


# 浏览器可内联预览的 MIME；其余（RAW/HEIC 等）按二进制流下发
MIME = {"jpg": "image/jpeg", "jpeg": "image/jpeg", "png": "image/png",
        "gif": "image/gif", "webp": "image/webp", "bmp": "image/bmp",
        "avif": "image/avif", "heic": "image/heic", "heif": "image/heif",
        "tif": "image/tiff", "tiff": "image/tiff",
        "mp4": "video/mp4", "m4v": "video/mp4",
        "mov": "video/quicktime", "webm": "video/webm",
        "mp3": "audio/mpeg", "m4a": "audio/mp4", "wav": "audio/wav",
        "flac": "audio/flac", "ogg": "audio/ogg"}


@app.get("/api/asset/{asset_id}/raw")
def raw(asset_id: int, download: int = 0):
    a = db.q("SELECT orig_name, ext FROM assets WHERE id=?", (asset_id,), one=True)
    if not a:
        raise HTTPException(404)
    p = config.ORIG_DIR / f"{asset_id}.{a['ext']}"
    if not p.exists():
        raise HTTPException(404)
    headers = {"Cache-Control": "max-age=86400"}
    if download:
        headers["Content-Disposition"] = \
            f"attachment; filename=\"{a['orig_name'] or asset_id}\""
    return FileResponse(p, media_type=MIME.get(a["ext"], "application/octet-stream"),
                        headers=headers)


@app.get("/api/asset/{asset_id}/face/{face_id}")
def face_crop(asset_id: int, face_id: int):
    f = db.q("SELECT * FROM faces WHERE id=? AND asset_id=?", (face_id, asset_id),
             one=True)
    if not f:
        raise HTTPException(404)
    a = db.q("SELECT ext FROM assets WHERE id=?", (asset_id,), one=True)
    img = thumbs.decode_for_faces(config.ORIG_DIR / f"{asset_id}.{a['ext']}", a["ext"])
    if img is None:
        raise HTTPException(404)
    x, y, w, h = f["x"], f["y"], f["w"], f["h"]
    m = int(max(w, h) * 0.35)
    box = (max(0, x - m), max(0, y - m), min(img.width, x + w + m),
           min(img.height, y + h + m))
    img = img.crop(box)
    img.thumbnail((240, 240))
    buf = io.BytesIO()
    img.save(buf, "WEBP", quality=82)
    return StreamingResponse(io.BytesIO(buf.getvalue()), media_type="image/webp")


# ---------------------------------------------------------------- 管理端

@app.get("/api/admin/overview")
def admin_overview(_: None = Depends(require_admin)):
    def du(p: Path) -> int:
        return sum(f.stat().st_size for f in p.glob("*") if f.is_file())
    users = db.q("""SELECT u.id, u.name, u.created_at,
                    (SELECT COUNT(*) FROM assets a WHERE a.uploader_id=u.id) uploads
                    FROM users u ORDER BY u.created_at""")
    return {
        "assets": db.q("SELECT COUNT(*) c FROM assets", one=True)["c"],
        "analyzed": db.q("SELECT COUNT(*) c FROM assets WHERE analyzed=1", one=True)["c"],
        "persons": db.q("SELECT COUNT(*) c FROM persons", one=True)["c"],
        "faces": db.q("SELECT COUNT(*) c FROM faces", one=True)["c"],
        "orig_bytes": du(config.ORIG_DIR),
        "thumb_bytes": du(config.THUMB_DIR),
        "users": [dict(u) for u in users],
        "faces_ready": faces.available(),
    }


@app.get("/api/admin/persons")
def admin_persons(_: None = Depends(require_admin)):
    rows = db.q("""SELECT p.id, p.name, p.claimed_by,
                   (SELECT COUNT(*) FROM faces f WHERE f.person_id=p.id) n
                   FROM persons p ORDER BY n DESC""")
    out = []
    for r in rows:
        if r["n"] == 0:
            continue
        face = db.q("""SELECT f.id fid, f.asset_id FROM faces f WHERE f.person_id=?
                       ORDER BY (f.w*f.h) DESC LIMIT 1""", (r["id"],), one=True)
        out.append({"id": r["id"], "name": r["name"], "count": r["n"],
                    "cover": f"/api/asset/{face['asset_id']}/face/{face['fid']}"
                    if face else None, "claimed_by": r["claimed_by"]})
    return out


@app.post("/api/admin/persons/{pid}/rename")
def admin_rename(pid: int, body: dict, _: None = Depends(require_admin)):
    db.exec("UPDATE persons SET name=? WHERE id=?",
            ((body.get("name") or "").strip()[:20] or None, pid))
    return {"ok": True}


@app.post("/api/admin/persons/{a}/merge/{b}")
def admin_merge(a: int, b: int, _: None = Depends(require_admin)):
    """把 a 并入 b。"""
    if a == b or not db.q("SELECT 1 FROM persons WHERE id=?", (a,), one=True):
        raise HTTPException(404)
    db.exec("UPDATE faces SET person_id=? WHERE person_id=?", (b, a))
    faces.recluster_mean(b)
    db.exec("DELETE FROM persons WHERE id=?", (a,))
    return {"ok": True}


@app.post("/api/admin/persons/{pid}/delete")
def admin_delete_person(pid: int, _: None = Depends(require_admin)):
    db.exec("UPDATE faces SET person_id=NULL WHERE person_id=?", (pid,))
    db.exec("DELETE FROM persons WHERE id=?", (pid,))
    return {"ok": True}


@app.post("/api/admin/recluster")
def admin_recluster(_: None = Depends(require_admin)):
    n = faces.recluster_all()
    return {"persons": n}


@app.post("/api/admin/wipe")
def admin_wipe(_: None = Depends(require_admin)):
    """清空相册（保留成员与口令）。"""
    for t in ("faces", "persons", "likes", "comments", "decisions", "assets"):
        db.exec(f"DELETE FROM {t}")
    for d in (config.ORIG_DIR, config.THUMB_DIR):
        for f in d.glob("*"):
            f.unlink(missing_ok=True)
    return {"ok": True}


@app.get("/api/admin/export")
def admin_export(_: None = Depends(require_admin)):
    """导出全部原片为 zip（旅行结束后备份用）。"""
    rows = db.q("SELECT id, orig_name, ext FROM assets ORDER BY id")
    tmp = config.DATA_DIR / "_export_all.zip"
    tmp.unlink(missing_ok=True)
    with zipfile.ZipFile(tmp, "w", zipfile.ZIP_STORED, allowZip64=True) as zf:
        used = set()
        for r in rows:
            p = config.ORIG_DIR / f"{r['id']}.{r['ext']}"
            if not p.exists():
                continue
            name = r["orig_name"] or f"{r['id']}.{r['ext']}"
            stem, dot, ext = name.rpartition(".")
            if not dot:
                stem, ext = name, r["ext"]
            i, uniq = 1, name
            while uniq.lower() in used:
                i += 1
                uniq = f"{stem}({i}).{ext}"
            used.add(uniq.lower())
            zf.write(p, arcname=uniq)
    return FileResponse(
        tmp, media_type="application/zip", filename="tuantu_export.zip",
        background=BackgroundTask(lambda: tmp.unlink(missing_ok=True)))


# ---------------------------------------------------------------- 静态页

app.mount("/static", StaticFiles(directory=config.BASE_DIR / "server" / "static"),
          name="static")


@app.get("/")
def index():
    return FileResponse(config.BASE_DIR / "server" / "static" / "index.html")


@app.get("/admin")
def admin_page():
    return FileResponse(config.BASE_DIR / "server" / "static" / "admin.html")


@app.get("/manifest.webmanifest")
def manifest():
    return FileResponse(config.BASE_DIR / "server" / "static" / "manifest.webmanifest",
                        media_type="application/manifest+json")
