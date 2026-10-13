// 连接逻辑：手动地址规范化、盒子识别（/api/status 必须是团图 JSON）、会话校验。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:tuantu_app/api.dart';

void main() {
  group('normalizeBase 手动地址', () {
    test('裸 IP 补 http 和端口', () {
      expect(Api.normalizeBase('192.168.50.42'), 'http://192.168.50.42:8000');
      expect(Api.normalizeBase(' 192.168.50.42 '), 'http://192.168.50.42:8000');
    });

    test('已有 scheme 或端口的保持不变', () {
      expect(Api.normalizeBase('http://192.168.50.42:8000'),
          'http://192.168.50.42:8000');
      expect(Api.normalizeBase('http://192.168.50.42:9000/'),
          'http://192.168.50.42:9000');
      expect(Api.normalizeBase('https://box.lan:8443'), 'https://box.lan:8443');
    });

    test('垃圾输入返回 null', () {
      expect(Api.normalizeBase(''), isNull);
      expect(Api.normalizeBase('not a url'), isNull);
    });
  });

  group('盒子探测与会话校验', () {
    late HttpServer server;
    var base = '';
    var meStatus = 200;
    var meBody = '{"id": 7, "name": "小明"}';
    var statusBody = '{"total": 3, "pending": 0, "persons": 0}';

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      base = 'http://127.0.0.1:${server.port}';
      server.listen((req) async {
        if (req.uri.path == '/api/status') {
          req.response.write(statusBody);
        } else if (req.uri.path == '/api/me') {
          req.response.statusCode = meStatus;
          req.response.write(meBody);
        } else {
          req.response.statusCode = 404;
          req.response.write('{"detail": "Not Found"}');
        }
        await req.response.close();
      });
    });

    tearDown(() async {
      await server.close(force: true);
    });

    test('团图 JSON 才算盒子', () async {
      expect(await Api.probe(base), isTrue);
      statusBody = '<html>not tuantu</html>';
      expect(await Api.probe(base), isFalse);
      statusBody = '{"total": 3}';
      expect(await Api.probe(base), isFalse, reason: '普通服务碰巧有 total 字段也不能冒充盒子');
      statusBody = '{"service": "tuantu", "protocol": 1}';
      expect(await Api.probe(base), isTrue);
      statusBody = '{"total": 3, "pending": 0, "persons": 0}';
    });

    test('sessionValid 校验 token', () async {
      expect(await Api.sessionValid(base, 'tok'), isTrue);
      meStatus = 401;
      meBody = '{"detail": "请先加入"}';
      expect(await Api.sessionValid(base, 'tok'), isFalse);
      expect(await Api.sessionValid(base, ''), isFalse);
    });

    test('peekBoxId 读身份，旧盒子没有该字段则返回 null', () async {
      statusBody = '{"service": "tuantu", "protocol": 1, "box_id": "bx-1"}';
      expect(await Api.peekBoxId(base), 'bx-1');
      statusBody = '{"service": "tuantu", "protocol": 1}';
      expect(await Api.peekBoxId(base), isNull);
    });
  });
}
