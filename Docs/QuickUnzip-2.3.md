# 轻解 QuickUnzip 2.3

适用于 Apple Silicon、macOS 13+ 的原生解压工具。交付包含 App、源码、测试、体验包和详细对标分析。当前为临时签名测试版，未完成 Apple 公证。

## 安装与 RAR 兼容性

双击 `QuickUnzip-2.3-macOS-arm64.pkg`，安装器会将应用放在「应用程序」中。应用采用本地临时签名，安装包未经 Apple 公证。

应用内置官方 7-Zip 26.06 for macOS arm64。此前的引擎能列出 RAR 目录，但缺少解压压缩成员所需的 RAR 编解码模块。使用新版后，实际含有加密 RAR 5 数据的 `st-12.zip` 已成功解压出 1 个文件，用时 0.63 秒。安装后即可使用内置解码器。「偏好设置 → 解压引擎」保留了手动更新入口。

## 2.3 更新

可用密码解开带传统 ZipCrypto 头的 BH 条目，以及能从块边界确定密文归属的固实 EGG。错误密码、认证标签错误或数据 CRC 错误时，任务不会发布已暂存的文件。BH Fuse（方法 3）尚无内置解码器。详见 `旧格式兼容性.md` 的样本范围和格式边界。

## 2.2 更新

- 分卷 ISZ 能直接还原为 ISO。将同组卷放在同一目录，打开 .isz、.i01 或 .part02.isz 均可开始。分卷 EGG 和 ALZ 直接跨卷读取，浏览目录时可以跳过成员数据。
- 压缩包目录初次读取最多 10,000 项，点击「加载更多条目」可以继续浏览、搜索和选择后面的条目。命令行示例为 `qunzip --list --limit 20000 archive.zip`。
- 完整性测试在原生引擎遇到未识别格式或不支持的方法时自动改用内置 7-Zip，已验证 WIM。旧 EGG 文件名增加简体、繁体中文和西欧代码页。

## 使用

拖入文件或 `⌘O` 添加归档。默认智能解压：单文件和单顶层目录直接输出，多顶层内容放入归档同名目录。设置中可改为始终独立目录或当前位置，并选择询问、重命名、跳过或替换重名文件。

任务的「查看内容」可浏览目录、搜索、排序、解锁加密目录、选择文件或文件夹解压、查看 ZIP 注释，并对支持的图片、文档、音视频使用系统 Quick Look。预览会临时解码选中文件，限制为 256 MiB；不自动执行文件。任务可做完整性测试、暂停、继续和取消。

支持代码页手动切换、NFC/NFD、分卷首卷定位、可选忽略 Mac 元数据、会话内密码记忆、40 条已结束任务记录和 Finder 服务声明。密码不进命令行参数、历史或磁盘设置。

Finder 服务需要系统识别该 App 并启用相应服务；注册为备用文件处理程序，不更改系统默认解压工具。Finder 服务是否出现在菜单与安装位置、macOS 设置有关。

## 性能

默认一次处理一个归档。均衡模式最多 2 个解码线程，速度优先最多 4 个，低占用 1 个。支持的 ZIP32 Store/Deflate 多成员归档使用原生并行通道，不满足条件的归档自动回退。并非每个算法都能并行。

原生读写缓冲有界，CPU 使用 Utility QoS；原生通道在热压力下主动让出资源。7-Zip 的字典内存由实际压缩方法决定，不保证所有包都只占用固定少量内存。不能保证对任意前台负载完全没有影响。

同机热缓存合成 ZIP 测试结果、SHA-256 验证和测量限制见 `benchmark-v2.json` 及对标文档。没有与 Bandizip 做同机性能比较。

## 构建与验证

需要现代 Xcode/Swift 工具链和 Python 3，无 Swift 网络依赖。

```bash
bash scripts/test.sh
bash scripts/build.sh
python3 scripts/benchmark.py
python3 scripts/package_release.py
```

App 在 `dist/QuickUnzip.app`。命令行工具在其 `Contents/MacOS/qunzip`，也可直接运行 `.build/release/qunzip --help`。

```bash
qunzip --list archive.zip
qunzip --test archive.7z
qunzip --smart --out /path/to/output archive.zip
qunzip --here --rename --select folder/data.csv archive.zip
# 密码从标准输入读取；不要把密码写入命令参数。
qunzip --password-stdin --test archive.7z
```

核心测试涵盖真实 RAR 5 样本、错后缀、加密 7z、错误密码、分卷、智能布局、冲突策略、选择性解压、负值元数据误判、CRC 损坏、内部安全链接、越界攻击、暂停取消和原生并行 ZIP。运行后以实际测试输出为准。

## 深度分析与剩余差距

阅读 [Bandizip 对标分析与实现记录](Bandizip_对标分析与实现记录.md)。其中逐项列出已实现、部分实现与未实现能力，并解释为何需要不同解压通道。

少见格式、样本覆盖和分支限制见 旧格式兼容性.md。ZIP 修复、密码恢复、Keychain 密码库、从条目列表拖出文件尚未实现。7-Zip 特殊链接不支持，原生通道只接受指向解压内容内部的安全链接。尚不提供创建或修改压缩包。

## 依赖与许可

系统 libarchive 和 zlib 为实际依赖；`Sources/CZipCodec` 是本项目的流式 API 桥接代码。安装包内置官方 7-Zip 26.06，许可证、对应源代码地址和下载来源见应用内的 `Contents/Resources/Licenses`。正式分发需提供对应版本来源、许可证与必要源代码材料，并完成签名、公证和更多安全测试。

公开 RAR 样本来自 libarchive 测试集，出处及 COPYING 在 `Tests/ArchiveCoreTests/Fixtures`。ZIPFoundation、XADMaster 和 Keka 是研究参考，未伪装成已集成的全部解码能力。
