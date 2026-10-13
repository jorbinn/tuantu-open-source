/// 本机盒子 SQLite，表结构和 Python 盒子对齐。
library;

import 'dart:io';
import 'dart:convert';
import 'dart:math';

import 'package:sqflite/sqflite.dart';

class BoxDb {
  BoxDb(this._db) : _personsRevision = _PersonsRevision();
  BoxDb._shared(this._db, this._personsRevision);
  final DatabaseExecutor _db;
  final _PersonsRevision _personsRevision;

  /// 人物表人工改动（认领/改名/团员标记/合并）的内存版本号。
  /// 重聚类进入 isolate 计算前记下，写回前核对：期间有人动过人物就放弃本轮，
  /// 用新快照重跑，避免旧快照覆盖刚做的人工修改。
  int get personsRev => _personsRevision.value;
  void bumpPersonsRev() => _personsRevision.value++;

  Database? get _database {
    final database = _db;
    return database is Database ? database : null;
  }

  /// 媒体在 [mediaRoot]，库放到 app 内部目录（外部存储上 SQLite/WAL 容易失败）。
  static Future<BoxDb> openIn(Directory mediaRoot,
      {bool databaseInRoot = false}) async {
    // iOS stores DB/WAL/SHM beside the media inside its verified no-backup root.
    // Android retains its existing internal database and external media paths.
    final internal = databaseInRoot
        ? '${mediaRoot.path}/tuantu.db'
        : '${await getDatabasesPath()}/tuantu.db';
    final extDb = File('${mediaRoot.path}/tuantu.db');
    final intDb = File(internal);
    final wipe = File('${mediaRoot.path}/WIPE');
    if (wipe.existsSync()) {
      for (final f in [
        intDb,
        File('$internal-wal'),
        File('$internal-shm'),
        extDb,
        File('${mediaRoot.path}/tuantu.db-wal'),
        File('${mediaRoot.path}/tuantu.db-shm'),
      ]) {
        try {
          if (f.existsSync()) f.deleteSync();
        } catch (_) {}
      }
      for (final sub in const ['orig', 'thumbs', 'avatars']) {
        final d = Directory('${mediaRoot.path}/$sub');
        try {
          if (d.existsSync()) d.deleteSync(recursive: true);
        } catch (_) {}
      }
      try {
        wipe.deleteSync();
      } catch (_) {}
    }
    final needCopy = internal != extDb.path &&
        extDb.existsSync() &&
        (!intDb.existsSync() || intDb.lengthSync() < extDb.lengthSync());
    if (needCopy) {
      await extDb.copy(internal);
      for (final suffix in const ['-wal', '-shm']) {
        final src = File('${mediaRoot.path}/tuantu.db$suffix');
        if (src.existsSync()) {
          await src.copy('$internal$suffix');
        }
      }
    }
    return open(internal);
  }

  static Future<BoxDb> open(String path) async {
    final db = await openDatabase(
      path,
      version: 1,
      onCreate: (d, _) => _ensureSchema(d),
      onUpgrade: (d, _, __) => _ensureSchema(d),
      onDowngrade: (d, _, __) => _ensureSchema(d),
      onOpen: (d) => _ensureSchema(d),
    );
    try {
      await db.execute('PRAGMA journal_mode=WAL');
      await db.execute('PRAGMA synchronous=NORMAL');
      await db.execute('PRAGMA temp_store=MEMORY');
      await db.execute('PRAGMA cache_size=-8000');
      await db.execute('PRAGMA busy_timeout=8000');
    } catch (_) {}
    // Per-connection staging keeps half-prepared uploads out of paginated
    // reads. Restart drops it, so interrupted work cannot hide assets forever.
    await db.execute(
      'CREATE TEMP TABLE IF NOT EXISTS pending_uploads '
      '(asset_id INTEGER PRIMARY KEY)',
    );
    await db.execute(
      'CREATE TEMP VIEW IF NOT EXISTS published_assets AS '
      'SELECT * FROM assets WHERE id NOT IN '
      '(SELECT asset_id FROM pending_uploads)',
    );
    return BoxDb(db);
  }

  static Future<void> _ensureSchema(Database d) async {
    await d.execute('''
CREATE TABLE IF NOT EXISTS users(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  name TEXT NOT NULL,
  device_id TEXT,
  token TEXT UNIQUE NOT NULL,
  is_admin INTEGER DEFAULT 0,
  avatar INTEGER NOT NULL DEFAULT 0,
  created_at REAL NOT NULL
);''');
    await _ensureDeviceIdentitySchema(d);
    await d.execute('''
CREATE TABLE IF NOT EXISTS box_meta(
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
);''');
    await d.execute('''
CREATE TABLE IF NOT EXISTS assets(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  uploader_id INTEGER NOT NULL,
  sha256 TEXT NOT NULL,
  orig_name TEXT NOT NULL,
  ext TEXT NOT NULL,
  kind TEXT NOT NULL,
  size INTEGER NOT NULL,
  width INTEGER, height INTEGER, duration REAL,
  taken_at REAL,
  has_thumb INTEGER DEFAULT 0,
  analyzed INTEGER DEFAULT 0,
  created_at REAL NOT NULL
);''');
    try {
      await d.execute(
        'ALTER TABLE assets ADD COLUMN has_live INTEGER NOT NULL DEFAULT 0',
      );
    } catch (_) {}
    try {
      await d.execute('ALTER TABLE assets ADD COLUMN live_pts INTEGER');
    } catch (_) {}
    // 旅行报告的时间口径：记录 taken_at 的来源，报告才能区分
    // 「相机墙钟」和「上传时间回退」。旧数据为 NULL，按兼容口径处理。
    try {
      await d.execute('ALTER TABLE assets ADD COLUMN time_source TEXT');
    } catch (_) {}
    try {
      await d.execute(
        'UPDATE assets SET taken_at = created_at WHERE taken_at IS NULL OR taken_at = 0',
      );
    } catch (_) {}
    await d.execute('''
CREATE TABLE IF NOT EXISTS likes(
  asset_id INTEGER NOT NULL,
  user_id INTEGER NOT NULL,
  created_at REAL NOT NULL,
  PRIMARY KEY(asset_id, user_id)
);''');
    await d.execute('''
CREATE TABLE IF NOT EXISTS comments(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  asset_id INTEGER NOT NULL,
  user_id INTEGER NOT NULL,
  body TEXT NOT NULL,
  created_at REAL NOT NULL
);''');
    await d.execute('''
CREATE TABLE IF NOT EXISTS decisions(
  user_id INTEGER NOT NULL,
  asset_id INTEGER NOT NULL,
  view TEXT NOT NULL,
  action TEXT NOT NULL,
  batch_no INTEGER NOT NULL,
  created_at REAL NOT NULL,
  PRIMARY KEY(user_id, asset_id, view)
);''');
    await d.execute('''
CREATE TABLE IF NOT EXISTS faces(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  asset_id INTEGER NOT NULL,
  x INTEGER, y INTEGER, w INTEGER, h INTEGER,
  embedding BLOB NOT NULL,
  person_id INTEGER
);''');
    await d.execute('''
CREATE TABLE IF NOT EXISTS views(
  user_id INTEGER NOT NULL,
  asset_id INTEGER NOT NULL,
  created_at REAL NOT NULL,
  PRIMARY KEY(user_id, asset_id)
);''');
    await d.execute('''
CREATE TABLE IF NOT EXISTS persons(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  mean_emb BLOB NOT NULL,
  name TEXT,
  claimed_by INTEGER,
  created_at REAL NOT NULL
);''');
    final personColumnsBefore = (await d.rawQuery('PRAGMA table_info(persons)'))
        .map((c) => c['name'])
        .toSet();
    final hadMemberStatus = personColumnsBefore.contains('member_status');
    // 团员标记：0=未标记 1=团员 2=非团员。只影响人物统计，不删任何数据。
    try {
      await d.execute(
        'ALTER TABLE persons ADD COLUMN member_status INTEGER NOT NULL DEFAULT 0',
      );
    } catch (_) {}
    try {
      await d.execute(
        'ALTER TABLE persons ADD COLUMN member_marked_by INTEGER',
      );
    } catch (_) {}
    try {
      await d.execute('ALTER TABLE persons ADD COLUMN member_marked_at REAL');
    } catch (_) {}
    try {
      await d.execute('ALTER TABLE persons ADD COLUMN cover_face_id INTEGER');
    } catch (_) {}
    await d.execute('''
CREATE TABLE IF NOT EXISTS person_claims(
  person_id INTEGER NOT NULL,
  user_id INTEGER NOT NULL,
  created_at REAL NOT NULL,
  PRIMARY KEY(person_id, user_id)
);''');
    try {
      await d.execute('''
INSERT OR IGNORE INTO person_claims(person_id, user_id, created_at)
SELECT id, claimed_by, created_at FROM persons WHERE claimed_by IS NOT NULL
''');
    } catch (_) {}
    // 历史多对多认领的迁移记录 + 待确认状态。resolved_at 为空表示待用户确认，
    // 非空则是纯粹的审计记录（接替/合并时被解除的旧关系）。
    await d.execute('''
CREATE TABLE IF NOT EXISTS claim_pending(
  person_id INTEGER NOT NULL,
  user_id INTEGER NOT NULL,
  created_at REAL NOT NULL,
  pending_at REAL NOT NULL,
  reason TEXT,
  resolved_at REAL,
  PRIMARY KEY(person_id, user_id)
);''');
    await _migrateClaimsOneToOne(d);
    // 第一次引入团员标记时，已有认领（含因历史冲突转入待确认的关系）
    // 都代表旅行成员。只执行一次，后续开库不能覆盖人工改成“非团员”的结果。
    if (!hadMemberStatus) {
      await d.execute('''
UPDATE persons SET member_status=1
WHERE EXISTS(SELECT 1 FROM person_claims c WHERE c.person_id=persons.id)
   OR EXISTS(SELECT 1 FROM claim_pending cp
             WHERE cp.person_id=persons.id AND cp.resolved_at IS NULL)
''');
    }
    for (final sql in const [
      'CREATE INDEX IF NOT EXISTS idx_assets_taken ON assets(taken_at)',
      'CREATE INDEX IF NOT EXISTS idx_assets_created ON assets(created_at)',
      'CREATE INDEX IF NOT EXISTS idx_assets_timeline_id '
          'ON assets(COALESCE(taken_at, created_at) DESC, id DESC)',
      'CREATE INDEX IF NOT EXISTS idx_assets_created_id '
          'ON assets(created_at DESC, id DESC)',
      'CREATE INDEX IF NOT EXISTS idx_assets_uploader_created_id '
          'ON assets(uploader_id, created_at DESC, id DESC)',
      'CREATE INDEX IF NOT EXISTS idx_assets_uploader_name_taken '
          'ON assets(uploader_id, orig_name, COALESCE(taken_at, created_at))',
      'CREATE INDEX IF NOT EXISTS idx_assets_uploader ON assets(uploader_id)',
      'CREATE INDEX IF NOT EXISTS idx_assets_kind ON assets(kind)',
      'CREATE INDEX IF NOT EXISTS idx_assets_sha ON assets(sha256)',
      'CREATE INDEX IF NOT EXISTS idx_likes_asset ON likes(asset_id)',
      'CREATE INDEX IF NOT EXISTS idx_comments_asset ON comments(asset_id)',
      'CREATE INDEX IF NOT EXISTS idx_views_asset ON views(asset_id)',
      'CREATE INDEX IF NOT EXISTS idx_decisions_asset ON decisions(asset_id)',
      'CREATE INDEX IF NOT EXISTS idx_faces_asset ON faces(asset_id)',
      'CREATE INDEX IF NOT EXISTS idx_faces_person ON faces(person_id)',
      'CREATE INDEX IF NOT EXISTS idx_claims_user ON person_claims(user_id)',
      'CREATE UNIQUE INDEX IF NOT EXISTS idx_users_device ON users(device_id) '
          'WHERE device_id IS NOT NULL',
    ]) {
      try {
        await d.execute(sql);
      } catch (_) {}
    }
    // 这两个索引是身份约束，建不起来就必须让开库失败，不能在不满足
    // 一对一的状态下继续提供认领接口。
    await d.execute(
      'CREATE UNIQUE INDEX IF NOT EXISTS idx_claims_person_1to1 '
      'ON person_claims(person_id)',
    );
    await d.execute(
      'CREATE UNIQUE INDEX IF NOT EXISTS idx_claims_user_1to1 '
      'ON person_claims(user_id)',
    );
  }

  /// 旧库多对多认领 → 一对一。冲突关系不静默保留任何一方，全部转入
  /// claim_pending 待确认（原关系和 created_at 都保留）。幂等：冲突清完后再跑
  /// 没有任何副作用。冲突集合先从原始关系完整计算，避免删除顺序改变判断。
  static Future<void> _migrateClaimsOneToOne(Database d) async {
    final conflicts = await d.rawQuery('''
SELECT person_id, user_id, created_at FROM person_claims
WHERE user_id IN (
  SELECT user_id FROM person_claims GROUP BY user_id HAVING COUNT(*) > 1
)
OR person_id IN (
  SELECT person_id FROM person_claims GROUP BY person_id HAVING COUNT(*) > 1
)
''');
    final now = DateTime.now().millisecondsSinceEpoch / 1000.0;
    for (final c in conflicts) {
      final pid = c['person_id'];
      final uid = c['user_id'];
      await d.execute(
        '''
UPDATE claim_pending SET pending_at=?, reason='migrate_conflict', resolved_at=NULL
WHERE person_id=? AND user_id=?
''',
        [now, pid, uid],
      );
      await d.execute(
        '''
INSERT OR IGNORE INTO claim_pending(
  person_id, user_id, created_at, pending_at, reason
) VALUES(?,?,?,?, 'migrate_conflict')
''',
        [pid, uid, c['created_at'], now],
      );
    }
    for (final c in conflicts) {
      await d.rawDelete(
        'DELETE FROM person_claims WHERE person_id=? AND user_id=?',
        [c['person_id'], c['user_id']],
      );
    }
    // claimed_by 从此只是 person_claims 的冗余缓存，每次迁移后对齐一次。
    await d.execute('''
UPDATE persons SET claimed_by =
  (SELECT user_id FROM person_claims WHERE person_claims.person_id = persons.id)
''');
    if (conflicts.isNotEmpty) debugMigratedClaims(conflicts.length);
  }

  static void debugMigratedClaims(int n) {
    // 留个钩子方便测试/日志观察，不接 flutter 依赖。
    assert(() {
      // ignore: avoid_print
      print('[claims] migrated $n conflicted claims to pending');
      return true;
    }());
  }

  /// 旧库用 users.name UNIQUE 当账号。升级后保留原 id/token 和全部作品关系，
  /// 改由 device_id 唯一识别；显示名称允许重名。
  static Future<void> _ensureDeviceIdentitySchema(Database d) async {
    final cols = await d.rawQuery('PRAGMA table_info(users)');
    final names = cols.map((c) => c['name']).toSet();
    final hasDeviceId = names.contains('device_id');
    final table = await d.rawQuery(
      "SELECT sql FROM sqlite_master WHERE type='table' AND name='users'",
    );
    final sql = table.isEmpty ? '' : (table.first['sql'] ?? '').toString();
    final nameIsUnique = RegExp(
      r'name\s+text\s+unique',
      caseSensitive: false,
    ).hasMatch(sql);
    if (hasDeviceId && !nameIsUnique) return;

    await d.execute('DROP TABLE IF EXISTS users_identity_new');
    await d.execute('''
CREATE TABLE users_identity_new(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  name TEXT NOT NULL,
  device_id TEXT,
  token TEXT UNIQUE NOT NULL,
  is_admin INTEGER DEFAULT 0,
  avatar INTEGER NOT NULL DEFAULT 0,
  created_at REAL NOT NULL
);''');
    final deviceExpr = hasDeviceId ? 'device_id' : 'NULL';
    final adminExpr = names.contains('is_admin') ? 'is_admin' : '0';
    final avatarExpr = names.contains('avatar') ? 'avatar' : '0';
    await d.execute('''
INSERT INTO users_identity_new(id,name,device_id,token,is_admin,avatar,created_at)
SELECT id,name,$deviceExpr,token,$adminExpr,$avatarExpr,created_at FROM users
''');
    await d.execute('DROP TABLE users');
    await d.execute('ALTER TABLE users_identity_new RENAME TO users');
  }

  Future<void> close() async {
    final d = _database;
    if (d != null) await d.close();
  }

  /// 本库身份。清库/重建后会变，不能靠 IP 判断是不是同一个盒子。
  Future<String> ensureBoxId() async {
    final row = await qOne("SELECT value FROM box_meta WHERE key='box_id'");
    final existing = row?['value']?.toString() ?? '';
    if (existing.isNotEmpty) return existing;
    final id = 'bx-${_token()}';
    await exec(
      "INSERT OR IGNORE INTO box_meta(key, value) VALUES('box_id', ?)",
      [id],
    );
    final again = await qOne("SELECT value FROM box_meta WHERE key='box_id'");
    return (again?['value']?.toString().isNotEmpty ?? false)
        ? again!['value'].toString()
        : id;
  }

  /// 短事务。回调里必须用传入的 [tx]，不要再用外层 BoxDb。
  Future<T> txn<T>(Future<T> Function(BoxDb tx) fn) async {
    final d = _database;
    if (d == null) return fn(this);
    return d.transaction((t) => fn(BoxDb._shared(t, _personsRevision)));
  }

  static double now() => DateTime.now().millisecondsSinceEpoch / 1000.0;

  Future<List<Map<String, Object?>>> q(
    String sql, [
    List<Object?> args = const [],
  ]) =>
      _db.rawQuery(sql, args);

  Future<Map<String, Object?>?> qOne(
    String sql, [
    List<Object?> args = const [],
  ]) async {
    final r = await _db.rawQuery(sql, args);
    return r.isEmpty ? null : r.first;
  }

  Future<int> exec(String sql, [List<Object?> args = const []]) async {
    return _db.rawInsert(sql, args);
  }

  Future<int> run(String sql, [List<Object?> args = const []]) =>
      _db.rawUpdate(sql, args);

  Future<Map<String, Object?>?> userByToken(String token) =>
      qOne('SELECT * FROM users WHERE token=?', [token]);

  Future<Map<String, Object?>?> userById(int id) =>
      qOne('SELECT * FROM users WHERE id=?', [id]);

  Future<Map<String, Object?>?> userByName(String name) =>
      qOne('SELECT * FROM users WHERE name=? ORDER BY id LIMIT 1', [name]);

  Future<Map<String, Object?>?> userByDevice(String deviceId) =>
      qOne('SELECT * FROM users WHERE device_id=?', [deviceId]);

  /// 新客户端按设备认人。首次升级时，同名且尚未绑定设备的旧账号会被接管，
  /// 从而保留该用户过去的上传、评论和选片记录。
  Future<String> ensureDeviceUser(String deviceId, String name) async {
    final byDevice = await userByDevice(deviceId);
    if (byDevice != null) return byDevice['token'] as String;
    final legacy = await qOne(
      'SELECT * FROM users WHERE device_id IS NULL AND name=? ORDER BY id LIMIT 1',
      [name],
    );
    if (legacy != null) {
      await run('UPDATE users SET device_id=? WHERE id=?', [
        deviceId,
        legacy['id'],
      ]);
      return legacy['token'] as String;
    }
    final token = _token();
    await exec(
      'INSERT INTO users(name, device_id, token, created_at) VALUES(?,?,?,?)',
      [name, deviceId, token, now()],
    );
    return token;
  }

  Future<String> ensureUser(String name) async {
    final u = await qOne(
      'SELECT * FROM users WHERE device_id IS NULL AND name=? ORDER BY id LIMIT 1',
      [name],
    );
    if (u != null) return u['token'] as String;
    final token = _token();
    await exec('INSERT INTO users(name, token, created_at) VALUES(?,?,?)', [
      name,
      token,
      now(),
    ]);
    return token;
  }

  static final _tokenRandom = Random.secure();
  static String _token() => base64Url.encode(
        List<int>.generate(32, (_) => _tokenRandom.nextInt(256)),
      );
}

class _PersonsRevision {
  int value = 0;
}
