"""SQLite 存取层。单进程 + 全局锁，旅行团规模（几千张、十来人）绰绰有余。"""
import json
import sqlite3
import threading
import time
import uuid

from . import config

_lock = threading.Lock()
_conn: sqlite3.Connection | None = None

SCHEMA = """
CREATE TABLE IF NOT EXISTS users(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  name TEXT NOT NULL,
  device_id TEXT,
  token TEXT UNIQUE NOT NULL,
  is_admin INTEGER DEFAULT 0,
  avatar INTEGER NOT NULL DEFAULT 0,
  created_at REAL NOT NULL
);
CREATE TABLE IF NOT EXISTS assets(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  uploader_id INTEGER NOT NULL,
  sha256 TEXT NOT NULL,
  orig_name TEXT NOT NULL,
  ext TEXT NOT NULL,
  kind TEXT NOT NULL,            -- image / video / audio
  size INTEGER NOT NULL,
  width INTEGER, height INTEGER, duration REAL,
  taken_at REAL,                 -- EXIF 拍摄时间 epoch；缺省用上传时间
  has_thumb INTEGER DEFAULT 0,
  analyzed INTEGER DEFAULT 0,    -- 人脸分析是否完成
  created_at REAL NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_assets_taken ON assets(taken_at);
UPDATE assets SET taken_at = created_at WHERE taken_at IS NULL OR taken_at = 0;
CREATE INDEX IF NOT EXISTS idx_assets_sha ON assets(sha256);
CREATE TABLE IF NOT EXISTS faces(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  asset_id INTEGER NOT NULL,
  x INTEGER, y INTEGER, w INTEGER, h INTEGER,
  embedding BLOB NOT NULL,
  person_id INTEGER
);
CREATE INDEX IF NOT EXISTS idx_faces_asset ON faces(asset_id);
CREATE INDEX IF NOT EXISTS idx_faces_person ON faces(person_id);
CREATE TABLE IF NOT EXISTS persons(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  mean_emb BLOB NOT NULL,
  name TEXT,
  claimed_by INTEGER,
  created_at REAL NOT NULL
);
CREATE TABLE IF NOT EXISTS person_claims(
  person_id INTEGER NOT NULL,
  user_id INTEGER NOT NULL,
  created_at REAL NOT NULL,
  PRIMARY KEY(person_id, user_id)
);
INSERT OR IGNORE INTO person_claims(person_id, user_id, created_at)
SELECT id, claimed_by, created_at FROM persons WHERE claimed_by IS NOT NULL;
CREATE TABLE IF NOT EXISTS likes(
  asset_id INTEGER NOT NULL,
  user_id INTEGER NOT NULL,
  created_at REAL NOT NULL,
  PRIMARY KEY(asset_id, user_id)
);
CREATE TABLE IF NOT EXISTS comments(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  asset_id INTEGER NOT NULL,
  user_id INTEGER NOT NULL,
  body TEXT NOT NULL,
  created_at REAL NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_comments_asset ON comments(asset_id);
CREATE TABLE IF NOT EXISTS decisions(
  user_id INTEGER NOT NULL,
  asset_id INTEGER NOT NULL,
  view TEXT NOT NULL,            -- 选片视图（timeline/random/mine/person:N 各自独立发牌）
  action TEXT NOT NULL,          -- keep / skip
  batch_no INTEGER NOT NULL,
  created_at REAL NOT NULL,
  PRIMARY KEY(user_id, asset_id, view)
);
"""


def init():
    global _conn
    _conn = sqlite3.connect(config.DB_PATH, check_same_thread=False, timeout=30)
    _conn.row_factory = sqlite3.Row
    with _lock:
        _conn.execute("PRAGMA journal_mode=WAL")
        _conn.execute("PRAGMA busy_timeout=8000")
        _conn.executescript(SCHEMA)
        _conn.commit()
    _migrate()


def _migrate():
    _migrate_users_identity()
    exec("""CREATE TABLE IF NOT EXISTS views(
      user_id INTEGER NOT NULL,
      asset_id INTEGER NOT NULL,
      created_at REAL NOT NULL,
      PRIMARY KEY(user_id, asset_id)
    )""")


def _migrate_users_identity():
    """把旧的按唯一名字认人迁移为按设备认人，并保留所有用户 id/token。"""
    global _conn
    with _lock:
        cols = {r["name"] for r in _conn.execute("PRAGMA table_info(users)")}
        row = _conn.execute(
            "SELECT sql FROM sqlite_master WHERE type='table' AND name='users'"
        ).fetchone()
        table_sql = (row["sql"] if row else "") or ""
        name_is_unique = "name text unique" in " ".join(table_sql.lower().split())
        if "device_id" not in cols or name_is_unique:
            device_expr = "device_id" if "device_id" in cols else "NULL"
            admin_expr = "is_admin" if "is_admin" in cols else "0"
            avatar_expr = "avatar" if "avatar" in cols else "0"
            _conn.execute("DROP TABLE IF EXISTS users_identity_new")
            _conn.execute("""CREATE TABLE users_identity_new(
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              name TEXT NOT NULL,
              device_id TEXT,
              token TEXT UNIQUE NOT NULL,
              is_admin INTEGER DEFAULT 0,
              avatar INTEGER NOT NULL DEFAULT 0,
              created_at REAL NOT NULL
            )""")
            _conn.execute(f"""INSERT INTO users_identity_new(
              id,name,device_id,token,is_admin,avatar,created_at)
              SELECT id,name,{device_expr},token,{admin_expr},{avatar_expr},created_at
              FROM users""")
            _conn.execute("DROP TABLE users")
            _conn.execute("ALTER TABLE users_identity_new RENAME TO users")
        _conn.execute("""CREATE UNIQUE INDEX IF NOT EXISTS idx_users_device
                       ON users(device_id) WHERE device_id IS NOT NULL""")
        _conn.commit()


def q(sql, args=(), *, one=False):
    with _lock:
        cur = _conn.execute(sql, args)
        rows = cur.fetchall()
        cur.close()
    if one:
        return rows[0] if rows else None
    return rows


def exec(sql, args=()) -> int:
    with _lock:
        cur = _conn.execute(sql, args)
        _conn.commit()
        return cur.lastrowid


def executemany(sql, seq):
    with _lock:
        _conn.executemany(sql, seq)
        _conn.commit()


def now() -> float:
    return time.time()


def j(obj) -> str:
    return json.dumps(obj, ensure_ascii=False)


def new_token() -> str:
    return uuid.uuid4().hex + uuid.uuid4().hex[:8]
