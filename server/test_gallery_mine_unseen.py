"""「有我的 · 只看未看过」回归：view=mine_unseen 的 SQL 必须同时满足
「包含我认领的人脸」和「我没看过」，且过滤发生在 LIMIT 之前（分页不漏图）。

运行（需要 Python 3.10+ 与 requirements 依赖）：
    python -m unittest server.test_gallery_mine_unseen -v
"""
import importlib
import os
import tempfile
import unittest

from fastapi.testclient import TestClient


class MineUnseenGalleryTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="tuantu_mine_unseen_")
        os.environ["TUANTU_DATA"] = self.tmp
        from server import config, db, main
        importlib.reload(config)
        importlib.reload(db)
        importlib.reload(main)
        self.db = db
        db.init()

    def tearDown(self):
        if getattr(self, "db", None) and self.db._conn is not None:
            try:
                self.db._conn.close()
            except Exception:
                pass

    def _join(self, name: str, device: str) -> TestClient:
        """每个用户一个 TestClient：join 会种下 tt_token cookie 且路由里
        cookie 优先于 X-Token，共用一个客户端会把请求串成最后加入的人。"""
        c = TestClient(self._app())
        r = c.post("/api/join", json={"name": name, "device_id": device})
        self.assertEqual(r.status_code, 200, r.text)
        return c

    def _app(self):
        from server import main
        return main.app

    def _insert_asset(self, uploader_id: int, name: str, taken: float) -> int:
        return self.db.exec(
            """INSERT INTO assets(uploader_id, sha256, orig_name, ext, kind,
               size, width, height, taken_at, has_thumb, analyzed, created_at)
               VALUES(?,?,?,?,?,?,?,?,?,0,1,?)""",
            (uploader_id, f"sha-{name}", name, "jpg", "image", 10,
             100, 100, taken, taken))

    def _ids(self, client: TestClient, view: str, **params) -> list:
        r = client.get("/api/gallery",
                       params={"view": view, "limit": 60, **params})
        self.assertEqual(r.status_code, 200, r.text)
        return [e["id"] for e in r.json()["items"]]

    def test_mine_returns_all_claimed_but_mine_unseen_filters_views(self):
        alice = self._join("alice", "device-alice")
        bob = self._join("bob", "device-bob")
        uid = self.db.q("SELECT id FROM users WHERE device_id=?",
                        ("device-alice",), one=True)["id"]

        a1 = self._insert_asset(uid, "me1.jpg", 1770000100.0)
        a2 = self._insert_asset(uid, "me2.jpg", 1770000200.0)
        plain = self._insert_asset(uid, "plain.jpg", 1770000300.0)

        now = self.db.now()
        pid = self.db.exec(
            "INSERT INTO persons(mean_emb, created_at) VALUES(?,?)",
            (b"\x00" * 16, now))
        for aid in (a1, a2):
            self.db.exec(
                "INSERT INTO faces(asset_id,x,y,w,h,embedding,person_id) "
                "VALUES(?,?,?,?,?,?,?)", (aid, 1, 1, 10, 10, b"\x00" * 16, pid))
        self.db.exec(
            "INSERT INTO person_claims(person_id, user_id, created_at) "
            "VALUES(?,?,?)", (pid, uid, now))

        # alice 看过 a1，没看过 a2
        r = alice.post("/api/seen", json={"asset_id": a1})
        self.assertEqual(r.status_code, 200, r.text)

        self.assertEqual(set(self._ids(alice, "mine")), {a1, a2},
                         "mine 不能被看过状态影响")
        self.assertNotIn(plain, self._ids(alice, "mine"),
                         "没有认领人物的不算「有我的」")
        self.assertEqual(self._ids(alice, "mine_unseen"), [a2],
                         "看过的一张必须被数据库过滤掉")
        self.assertEqual(self._ids(bob, "mine"), [],
                         "bob 没有认领任何人物")

        # 别人看过不算：bob 看了 a2，alice 的 mine_unseen 仍含 a2
        bob.post("/api/seen", json={"asset_id": a2})
        self.assertEqual(self._ids(alice, "mine_unseen"), [a2],
                         "「未看过」只看当前用户自己的 views")

        # 分页：过滤必须发生在 LIMIT 之前（每页 1 张，第一页只有 a2，翻页后为空）
        page1 = alice.get("/api/gallery",
                          params={"view": "mine_unseen", "limit": 1}).json()
        self.assertEqual([e["id"] for e in page1["items"]], [a2])
        page2 = alice.get("/api/gallery",
                          params={"view": "mine_unseen", "limit": 1,
                                  "cursor": page1["cursor"]}).json()
        self.assertEqual(page2["items"], [],
                         "看过的 a1 不允许在后续页漏出来")


if __name__ == "__main__":
    unittest.main()
