# 可选的人脸模型

默认源码包可以构建、开盒、上传和浏览；没有权重时人脸识别不可用，不会静默从网络下载模型。

## Flutter 手机盒子

当前推理代码对应 InsightFace buffalo_l 的 SCRFD-10G 检测器及 512 维 ArcFace 识别器。文件名为 `det_10g.onnx` 与 `w600k_r50.onnx`，配置位置为 `app/assets/models/`，放入后重新构建。其他架构的模型不能只改文件名替代，必须适配输入/输出和向量维度并验证。

上游 [InsightFace 许可说明](https://github.com/deepinsight/insightface#license) 区分：代码是 MIT，预训练模型/训练数据仅供非商业研究。GPL 源码授权不改变这一限制。本仓库不提供模型副本或自动下载脚本。请先确认自己的用途获得授权，再自行获取匹配权重；商用应获得授权或更换兼容且有合适许可的模型。

## Python / Web 盒子

早期服务端使用 OpenCV Zoo 的 YuNet + SFace，放在根目录 `models/`。`scripts/download_models.py` 是可选下载工具，仅在你明确执行时联网。先阅读上游各模型目录的 LICENSE 和模型说明，确认适用用途；不要把两个平台的人脸向量混用。

- [YuNet](https://github.com/opencv/opencv_zoo/tree/main/models/face_detection_yunet)
- [SFace](https://github.com/opencv/opencv_zoo/tree/main/models/face_recognition_sface)

权重文件被 `.gitignore` 排除；不要在 PR、release artifact 或公开 CI 中自动捆绑未经审核的权重。
