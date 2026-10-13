import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tuantu_app/device_identity.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('设备编号只生成一次并永久复用', () async {
    final first = await DeviceIdentity.ensureId();
    final second = await DeviceIdentity.ensureId();
    expect(second, first);
    expect(
        first,
        matches(RegExp(
          r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
        )));
  });

  test('名称第一次保存后可在连接其他盒子时直接复用', () async {
    expect(await DeviceIdentity.savedName(), isNull);
    await DeviceIdentity.saveName(' 小明 ');
    expect(await DeviceIdentity.savedName(), '小明');
  });
}
