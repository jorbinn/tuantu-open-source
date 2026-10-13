"""冒烟测试：加入 → 上传 → 等分析 → 发牌 → 决策 → 确认 → zip 下载 → 人物 → 管理台。"""
import io
import os
import time
import urllib3
import warnings
import zipfile
from pathlib import Path

import requests
from PIL import Image, ImageDraw

BASE = os.environ.get("TUANTU_BASE", "http://127.0.0.1:8000")
if BASE.startswith("https"):
    warnings.filterwarnings("ignore")
    urllib3.disable_warnings()
ok = lambda name: print(f"  ✅ {name}")


def make_session():
    s = requests.Session()
    if BASE.startswith("https"):
        s.verify = False
    return s


def make_img(color, size=(900, 1200), label=""):
    img = Image.new("RGB", size, color)
    d = ImageDraw.Draw(img)
    d.ellipse([size[0] // 4, size[1] // 4, size[0] * 3 // 4, size[1] * 3 // 4], fill="white")
    if label:
        d.text((20, 20), label, fill="black")
    buf = io.BytesIO()
    img.save(buf, "JPEG", quality=90)
    return buf.getvalue()


def main():
    # 清库，保证断言与数据量无关
    s = make_session()
    r = s.post(BASE + "/api/admin/wipe", headers={"X-Admin-Token": "admin"})
    assert r.ok, "管理口令不对？"

    # 首页
    r = s.get(BASE + "/")
    assert r.status_code == 200 and "团图" in r.text, "首页挂了"
    ok("首页 /")

    # 静态资源与管理台
    for path, kw in [("/admin", "管理台"), ("/static/style.css", ".swipe-stage"),
                     ("/static/app.js", "createApp"),
                     ("/static/vendor/vue.global.prod.js", "Vue"),
                     ("/manifest.webmanifest", "团图"),
                     ("/static/icons/icon-192.png", "")]:
        r = s.get(BASE + path)
        assert r.status_code == 200, f"{path} 404"
        if kw:
            assert kw in r.text, f"{path} 内容不对"
    ok("静态资源 / 管理台页 / manifest / 图标")

    # 口令错误拒绝
    r = s.post(BASE + "/api/join", json={"name": "小明", "code": "0000"})
    assert r.status_code == 403, "口令校验失效"
    ok("错误口令被拒绝")

    # 正确加入
    r = s.post(BASE + "/api/join", json={"name": "小明", "code": "8888"})
    assert r.status_code == 200, r.text
    ok("加入房间（token/cookie）")

    # 上传 6 张 + 1 个不支持的
    files = []
    for i, c in enumerate([(200, 60, 60), (60, 200, 60), (60, 60, 200),
                           (200, 200, 60), (200, 60, 200), (60, 200, 200)]):
        files.append(("files", (f"IMG_{4000 + i}.jpg", make_img(c, label=str(i)), "image/jpeg")))
    files.append(("files", ("virus.exe", b"MZ...", "application/octet-stream")))
    r = s.post(BASE + "/api/upload", files=files)
    assert r.status_code == 200, r.text
    d = r.json()
    assert len(d["accepted"]) == 6 and len(d["rejected"]) == 1, d
    ok(f"上传 6 张成功、1 个拒绝（{d['rejected'][0]}）")

    # 重复上传去重
    r = s.post(BASE + "/api/upload",
               files=[("files", ("IMG_4000_copy.jpg", make_img((200, 60, 60), label="0"), "image/jpeg"))])
    assert len(r.json()["duplicates"]) == 1, r.text
    ok("SHA256 去重生效")

    # 第二个用户加入
    s2 = make_session()
    s2.post(BASE + "/api/join", json={"name": "小红", "code": "8888"})

    # 等后台分析完
    for _ in range(60):
        st = s.get(BASE + "/api/status").json()
        if st["pending"] == 0:
            break
        time.sleep(0.5)
    assert st["pending"] == 0, "后台分析卡住了"
    ok(f"后台分析完成（{st['total']} 张，缩略图+EXIF）")

    # 缩略图可访问
    first_id = d["accepted"][0]["id"]
    r = s.get(BASE + f"/api/asset/{first_id}/thumb")
    assert r.status_code == 200 and r.headers["content-type"] == "image/webp"
    ok("缩略图 webp 输出")

    # 发牌
    r = s.get(BASE + "/api/deal?view=timeline").json()
    assert len(r["cards"]) == 6 and r["batch_no"] == 1, r
    ok(f"发牌 {len(r['cards'])} 张，批号 {r['batch_no']}")
    ids = [c["id"] for c in r["cards"]]

    # 决策：keep 3 张、skip 3 张；点 1 个赞
    for i, aid in enumerate(ids):
        r = s.post(BASE + "/api/decide",
                   json={"asset_id": aid, "action": "keep" if i < 3 else "skip",
                         "batch_no": 1, "view": "timeline"})
        assert r.ok
    s.post(BASE + "/api/like", json={"asset_id": ids[0]})
    r = s.post(BASE + "/api/like", json={"asset_id": ids[0]}).json()  # 再点取消
    assert r["liked"] is False
    s.post(BASE + "/api/like", json={"asset_id": ids[0]})
    ok("决策上报 + 点赞/取消点赞")

    # 小红看到的赞数
    c0 = s2.get(BASE + "/api/deal?view=all").json()["cards"]
    liked = [c for c in c0 if c["id"] == ids[0]][0]
    assert liked["likes"] == 1 and liked["uploader"] == "小明"
    ok(f"赞全员可见（likes={liked['likes']}，作者={liked['uploader']}）")

    # 批次确认 + zip 下载（按视图）
    r = s.post(BASE + "/api/batch/1/confirm?view=timeline").json()
    assert r["keep"] == 3, r
    r = s.get(BASE + r["url"])
    assert r.status_code == 200, r.status_code
    zf = zipfile.ZipFile(io.BytesIO(r.content))
    assert len(zf.namelist()) == 3, zf.namelist()
    ok(f"批次确认 + zip 下载（{zf.namelist()}）")

    # 时间线发过牌的不再出现；随机视图仍能拿到全部 6 张（视图独立发牌）
    r = s.get(BASE + "/api/deal?view=timeline").json()
    assert len(r["cards"]) == 0, r
    r = s.get(BASE + "/api/deal?view=random").json()
    assert len(r["cards"]) == 6, r
    ok("视图独立发牌（时间线看完，随机仍全量）")

    # 相册浏览
    g = s.get(BASE + "/api/gallery?view=all").json()
    assert len(g["items"]) == 6
    ok("相册分页浏览")

    idx = s.get(BASE + "/api/me/upload_index").json()
    assert isinstance(idx.get("items"), list) and len(idx["items"]) == 6, idx
    assert idx["items"][0]["name"] and idx["items"][0]["day"]
    ok("上传去重索引（文件名+日期）")

    mine = s.get(BASE + "/api/me/assets").json()
    assert len(mine["items"]) == 6 and all(x["mine"] is True for x in mine["items"]), mine
    empty = s2.get(BASE + "/api/me/assets").json()
    assert empty["items"] == [], empty
    ok("个人作品只含自己上传的")

    uid = s.get(BASE + "/api/me").json()["id"]
    other = s2.get(BASE + f"/api/user/{uid}").json()
    assert other["name"] == "小明" and other["uploaded"] == 6, other
    works = s2.get(BASE + f"/api/user/{uid}/assets").json()
    assert len(works["items"]) == 6 and all(x["uploader"] == "小明" for x in works["items"])
    ok("访客可看对方主页作品")

    # 管理台（wipe 保留成员，只按名字断言）
    h = {"X-Admin-Token": "admin"}
    r = s.get(BASE + "/api/admin/overview", headers=h).json()
    names = {u["name"]: u["uploads"] for u in r["users"]}
    assert r["assets"] == 6 and names.get("小明") == 6 and names.get("小红") == 0, r
    ok("管理台总览（资产/成员）")
    r = s.post(BASE + "/api/admin/recluster", headers=h).json()
    assert "persons" in r
    ok("全量重聚类")

    # 无口令访问管理台被拒
    assert s.get(BASE + "/api/admin/overview").status_code == 401
    ok("管理台口令保护")

    # 详情
    det = s.get(BASE + f"/api/asset/{ids[0]}/detail").json()
    assert det["liked_by"] == ["小明"], det
    ok("照片详情 + 点赞人列表")

    # 评论（存在开了服务的盒子上）
    bad = s.post(BASE + f"/api/asset/{ids[0]}/comments", json={"body": "   "})
    assert bad.status_code == 400, bad.text
    r = s.post(BASE + f"/api/asset/{ids[0]}/comments", json={"body": "这张好看"}).json()
    assert r["body"] == "这张好看" and r["name"] == "小明", r
    r2 = s2.post(BASE + f"/api/asset/{ids[0]}/comments", json={"body": "同意"}).json()
    assert r2["name"] == "小红", r2
    clist = s.get(BASE + f"/api/asset/{ids[0]}/comments").json()["comments"]
    assert [c["body"] for c in clist] == ["这张好看", "同意"], clist
    g = s.get(BASE + "/api/gallery?view=all").json()
    item = [x for x in g["items"] if x["id"] == ids[0]][0]
    assert item["comments"] == 2, item
    ok("评论写入盒子并全员可见")

    # 个人主页：上次上传、按赞排序、改名、头像、删除
    me = s.get(BASE + "/api/me").json()
    assert me["uploaded"] == 6 and me["last_upload"], me
    assert me["name"] == "小明" and me["id"]
    ok("我的：上传数与上次上传时间")

    g = s.get(BASE + "/api/gallery?view=uploaded&sort=likes").json()
    assert len(g["items"]) == 6, g
    assert g["items"][0]["id"] == ids[0], g["items"][0]
    g2 = s.get(BASE + "/api/gallery?view=uploaded&sort=comments").json()
    assert g2["items"][0]["id"] == ids[0]
    ok("作品按点赞/评论量排序")

    r = s.post(BASE + "/api/me/profile", json={"name": "小明改"}).json()
    assert r["name"] == "小明改", r
    assert s.get(BASE + "/api/me").json()["name"] == "小明改"
    s.post(BASE + "/api/me/profile", json={"name": "小明"})
    ok("改名字")

    r = s.post(BASE + "/api/me/avatar",
               files={"file": ("a.jpg", make_img((10, 20, 30)), "image/jpeg")})
    assert r.status_code == 200, r.text
    av = r.json()["avatar"]
    r = s.get(BASE + av.split("?")[0] if "?" in av else av)
    assert r.status_code == 200 and r.headers["content-type"] == "image/webp"
    ok("上传头像")

    forbidden = s2.delete(BASE + f"/api/asset/{ids[0]}")
    assert forbidden.status_code == 403, forbidden.text
    gone = ids[-1]
    r = s.delete(BASE + f"/api/asset/{gone}")
    assert r.status_code == 200, r.text
    g = s2.get(BASE + "/api/gallery?view=all").json()
    assert gone not in [x["id"] for x in g["items"]]
    assert s.get(BASE + f"/api/asset/{gone}/detail").status_code == 404
    ok("只能删自己的，删除后别人看不见")

    print("\n🎉 全部冒烟测试通过")


if __name__ == "__main__":
    main()
