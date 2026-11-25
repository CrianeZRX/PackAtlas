# 发布 PackAtlas

推送 `main`、提交 PR 或手动运行工作流时，GitHub Actions 只构建和上传 Artifacts。推送 `v*` 版本标签时，[PackAtlas builds](../.github/workflows/workbench.yml) 还会在 macOS、Windows 和 Ubuntu 全部构建成功后，自动创建 GitHub Release。

## 发布新版本

1. 将版本号写入 [`Workbench/package.json`](../Workbench/package.json)，并提交、推送到 `main`。三个平台的安装包版本均从该文件读取。
2. 在要发布的提交上创建同版本的标签，标签比版本号多一个 `v`。以 `3.0.0-preview.1` 为例：

   ```bash
   git tag -a v3.0.0-preview.1 -m "PackAtlas 3.0.0 Preview 1"
   git push origin v3.0.0-preview.1
   ```

3. 在 [GitHub Actions](https://github.com/CrianeZRX/PackAtlas/actions/workflows/workbench.yml) 查看该标签对应的运行。成功后到 [GitHub Releases](https://github.com/CrianeZRX/PackAtlas/releases) 下载 macOS `.pkg`、Windows 安装版与便携版 `.exe`、Ubuntu `.deb` 与 `.AppImage`。

带预发布后缀的版本（如 `-preview.1`）会标记为 **Pre-release**。发布任务不会覆盖同标签已发布的 Release。如果附件上传失败留下了同名草稿，先在 Releases 页面检查草稿，再决定补齐附件后发布，或清理草稿后重跑任务。

发布任务使用 GitHub Actions 的内置令牌，不需要添加个人访问令牌。自动发布不改变各平台的签名或公证状态。源码采用 MIT 许可，第三方组件沿用各自的许可证，见 [THIRD_PARTY.md](../THIRD_PARTY.md)。
