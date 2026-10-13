# 第三方许可与素材来源

GPL-3.0-only 适用于本仓库原创源码和新生成的通用背景、测试素材；不替代第三方许可证，也不授予未包含的模型或商标权利。

- **Flutter / Dart / 插件**：依赖与精确版本见 `app/pubspec.yaml`、`app/pubspec.lock`，原生依赖另见 Gradle、Podfile.lock。依赖按其原许可证提供，分发时须保留相应许可通知。Flutter 模板代码沿用 Flutter 的 BSD-3-Clause 许可（见 `LICENSES/Flutter-BSD-3-Clause.txt`）。
- **Vue 3.4.38**：`server/static/vendor/vue.global.prod.js`，保留原作者头部；MIT 许可证在 `LICENSES/Vue-MIT.txt`，来源 [vuejs/core](https://github.com/vuejs/core/tree/v3.4.38)。
- **Python 依赖**：见 `requirements.txt`。不将通过包管理器安装的依赖重新授权为 GPL；发行时核查实际版本的依赖许可证。
- **ONNX Runtime / InsightFace**：保留调用和推理实现。InsightFace 代码的 MIT 许可与预训练模型的许可不同；上游预训练权重仅供非商业研究，因此本仓库不包含、不自动下载这些权重。详见 [模型说明](docs/models.md)。
- **报告背景、应用图标**：由 `scripts/generate_public_assets.py` 使用基本几何图形生成，不使用私人旅行照或旧参考报告。
- **媒体测试样本**：由 `scripts/generate_test_media.py`、`scripts/make_live_lpcm_fixture.mjs` 使用 ffmpeg 的合成图案/正弦波生成，不含真人或真实录音。ffmpeg 是外部开发工具，不包含在本仓库中。
- **系统接口与媒体格式**：Android、iOS、QuickTime 等名称用于说明兼容性。设备导出的专有 Vivo UUID 二进制模板未公开。

分发自行构建的二进制时，应一并提供 GPL 所要求的对应源码、构建说明与实际捆绑第三方组件的通知。未取得另外授权前，不要将受限制模型放进发行包。
