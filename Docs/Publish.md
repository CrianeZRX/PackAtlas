# 首次发布到 GitHub

仓库建议为 CrianeZRX/packatlas，可见性为 Public。2026-11-25 本地构建阶段尚未创建该远程仓库。首次发布建议使用源码包解出后得到的干净 PackAtlas 目录。

    gh auth login --hostname github.com --git-protocol https --web
    gh auth refresh --hostname github.com --scopes workflow
    git init -b main
    git add .
    git status --short
    git commit -m "Initial PackAtlas preview"
    gh repo create CrianeZRX/packatlas --public --source . --remote origin --push

git status 的输出应只有源码、字体及其许可证、合成样例、测试向量和构建配置。发布包排除了本机运行环境、编译结果和历史安装包。首次推送后查看 **Actions → PackAtlas builds**。运行成功后，在对应 run 的 **Artifacts** 中下载各平台包。GitHub Actions 不会自动创建 Release 或为安装包做平台签名、公证。

如果 GitHub 上已创建同名空仓库，给本地仓库添加它作为 origin，然后推送 main。此项目的源代码按 MIT 整理。第三方组件及字体沿用各自的许可证与署名，详见 [THIRD_PARTY.md](../THIRD_PARTY.md)。
