# 展卷 PackAtlas 工作台设计

## 界面

参考 [RackBook](https://github.com/CrianeZRX/rackbook) 的纸面网格、墨线边框、红笔批注和手写层级。解压工作台使用自己绘制的压缩包剖面图。图上的格式随选中的真实归档更新，完成后显示任务状态。表单、文件名和诊断文本使用高可读性的字体。

左侧聚合队列、历史和语言。中间是压缩包图解、可搜索的成员目录和近期结果。右侧设定输出目录、布局、资源使用和重名策略。解压、完整性测试和目录浏览各有明确入口。

## 平台和解码路径

| 平台 | 窗口 | 解码路径 | 构建产物 |
| --- | --- | --- | --- |
| macOS 13+ · Apple Silicon | AppKit / WKWebView | 既有 ArchiveCore，原生 ZIP 快速路径、7-Zip、旧格式模块 | .pkg |
| Windows · x64 | Electron | 7-Zip 26.06 | NSIS .exe、便携 .exe |
| Ubuntu 24.04 · x64 | Electron | 7-Zip 26.06 | .deb、.AppImage |

三个窗口共享 Workbench/ui。JavaScript 负责视图、表单与六套翻译。宿主提供原生文件选择、拖放、浏览、解压、测试、取消和显示输出。文件内容保留在本机，密码在当前操作中使用，从标准输入传给解码器。历史记录只保存用于显示的文件名、结果和输出位置。

macOS 沿用 2.3 的引擎和资源限制。Windows 与 Ubuntu 首版优先覆盖 ZIP、RAR、7z 和常见 TAR、GZIP、XZ、BZIP2 容器。EGG、ALZ、ISZ、BH 等原生兼容模块仍只在 macOS 中提供。已知方法边界见 [旧格式兼容性](旧格式兼容性.md)。

## 后续路线

1. 在两种非 macOS 目标系统上验证安装、拖放、Unicode 目录、密码输入和分卷。
2. 将公共格式测试扩展到 ZIPX、加密 RAR、新版 RAR 7、不同大小的固实包及同名输出。记录吞吐量和前台负载。
3. 按模块移植旧格式适配器。每个适配器以公开样本、原文比对和错误密码或 CRC 回归为准。BlakHole Fuse 仍需要可分发的实现和真实样本。
4. 在发布稳定版前补齐文件关联、升级、签名与公证，分别验证 Apple Silicon、Intel Mac、Linux ARM64 和 Windows ARM64。
