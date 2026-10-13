# 团图 · Tuantu

一个面向同行者的离线共享相册。让一台手机作为局域网照片盒子，其他手机加入后上传、浏览、评论和保存照片与视频。支持 Android 与 iOS，包含 Flutter 应用和可选的 Python / Web 服务端。

**开源候选版，许可证 GPL-3.0-only。** 此仓库从脱敏后的源码快照开始，不含私人提交历史、照片库、账号、签名、热点口令和商店发布配置。自行构建的应用与现有商店版本使用不同的示例标识。

## 能做什么

- 同一 Wi-Fi 或个人热点下发现盒子，也可手动输入盒子的局域网地址。
- 上传照片、HEIC、视频及其他支持的媒体，浏览缩略图信息流、点赞、评论、选片和下载原片。
- Android 作为盒子运行前台服务；iPhone/iPad 可作为**前台盒子**，必须保持 App 在前台。
- iOS 盒子原片、缩略图和数据库保存在应用本机目录，并在开启服务前设置、校验系统备份排除标记。
- 本地人物聚类与认领代码、旅行报告及纪念卡布局。**本仓库不附带人脸模型权重**，未配置时不能识别人脸；上传与浏览可独立使用。

iOS 切后台、手动锁屏可能中断共享，回到前台后尝试恢复。主动“保存到系统相册”的副本仍受系统 iCloud 照片设置控制。卸载应用会删除应用内盒子数据，须自行保留原片。

## 构建 Flutter 应用

推荐 Flutter **3.47.3**、Android SDK 36、JDK 17 或兼容版本；iOS 最低 15.0，构建需要 macOS、Xcode 和 CocoaPods。建议使用纯英文工作目录。

```sh
git clone https://github.com/jorbinn/tuantu-open-source.git
cd tuantu-open-source/app
flutter pub get
flutter analyze
flutter test
flutter run
```

仓库已经附带通用背景和合成测试视频，不需要私人素材。模型目录只含说明文件，默认构建不下载或打包模型。需要识别时先阅读 [模型配置与许可](docs/models.md)。

Android 调试/自测包：`flutter build apk --release`。默认使用本机 debug 签名；对外发行请配置自己的 `TUANTU_KEYSTORE_PATH`、`TUANTU_KEYSTORE_PASSWORD`、`TUANTU_KEY_ALIAS`、`TUANTU_KEY_PASSWORD`，并修改 `applicationId`。不要尝试覆盖安装其他签名的版本。

iOS 模拟器：`flutter build ios --simulator --debug`。真机或分发时在 `ios/Runner.xcworkspace` 中设置自己的 Bundle Identifier 与 Development Team；仓库使用 `org.example.tuantu`，不含开发者账号。未提供自动上传 App Store / TestFlight 的工作流。

如需预配置热点，将 `config/hotspot.example.json` 复制为被忽略的 `config/hotspot.local.json`，自行填写后通过 `--dart-define-from-file=config/hotspot.local.json` 构建。发布的二进制可以被提取常量，**不要使用私人常用 Wi-Fi 密码**；默认无需预配置热点。

## 使用

1. 所有设备连到同一个 Wi-Fi，或先在系统设置开启热点。
2. 团长选择“我来当盒子”，iOS 需要保持前台，建议接电。
3. 同伴发现并加入；发现失败时从盒子设置复制实际 LAN 地址。不要把 `127.0.0.1` 填到其他手机上。
4. 上传后浏览、评论或保存。服务面向可信的同行局域网，不能直接暴露到公网。

## Python / Web 服务端（可选）

`server/` 是早期独立 FastAPI / PWA 实现，Flutter 手机盒子不依赖它；两种实现的功能与数据目录有差异。建议优先使用 Flutter 版本。

```sh
python -m venv .venv
# 激活虚拟环境后：
pip install -r requirements.txt
# 设置 TUANTU_ADMIN_CODE 为自己的管理口令；可选 TUANTU_ROOM_CODE
python -m uvicorn server.main:app --host 0.0.0.0 --port 8000
```

打开 `http://localhost:8000`；管理台是 `/admin`。运行数据在 `data/`，已忽略。视频封面需要 ffmpeg；人脸模型与许可见 [模型说明](docs/models.md)。默认示例管理口令 `admin` 仅适合隔离的开发环境，实际使用必须通过环境变量修改。`scripts/smoke_test.py` 会清空目标测试库，只能对临时测试实例使用。

## 开源版资源边界

- 报告底景替换成 20 张可再生成的通用抽象图，保留 7 类照片布局；旧景点 ID 仅作为兼容键保留，不对应私人行程。
- 测试视频由 ffmpeg 的图案与正弦波生成，不含真实录音、人像、定位或设备拍摄信息。
- 未公开从设备导出的 Vivo 专用 UUID 模板，因此 Vivo 特定实况导出暂不支持；识别/解析源码与其他平台导出路径仍保留，原片仍可下载。后续可用经审查的独立实现补齐。
- 人脸权重、私人报告参考图和商店签名不包含在 GPL 授权范围内，也不在仓库中。

## 验证与贡献

CI 运行 Flutter 静态检查、全量测试、Android 构建、iOS 模拟器原生隐私测试及源码隐私检查。设备权限、热点并发、视频体验、真实系统备份与长时间温度/内存仍需真机验证，CI 通过不代表这些已经验收。

提交前阅读 [CONTRIBUTING.md](CONTRIBUTING.md)、[SECURITY.md](SECURITY.md) 和 [第三方许可说明](THIRD_PARTY_NOTICES.md)。请勿提交真实照片、数据库、用户 token、Wi-Fi 密码、签名或设备记录。

本项目原创部分按 [GNU GPL v3](LICENSE)（GPL-3.0-only）提供。分发修改版需遵循 GPL 的对应源码等要求；第三方组件保留各自许可证。
