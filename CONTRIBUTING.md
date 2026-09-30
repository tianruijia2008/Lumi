# 参与贡献

谢谢你愿意帮 Lumi 变得更好。这是一个业余维护的个人项目，回复可能会慢，请多包涵。

## 提 issue

- 写清楚 macOS 版本、Lumi 的提交号（`git rev-parse --short HEAD`）、复现步骤。
- 翻译结果不理想时，附上原文、用的是哪个引擎、你期望的译文。
- **不要贴 API Key**，也不要贴含有个人信息的截图。

## 提 PR

1. 大一点的改动先开 issue 聊一下方向，免得白做。
2. 本地编译并实际跑过：`./build.sh debug && ./run.sh`。项目要求 macOS 26，CI 只做静态检查，不会替你编译。
3. 提交前跑一遍仓库守卫，并启用提交钩子：

   ```bash
   ./scripts/install-hooks.sh
   python3 scripts/security-scan.py
   ```

4. 改了 `Sources/Lumi/` 的文件数量或行数，要同步 `STRUCTURE.md` 第 3 节，否则守卫会报文档漂移。
5. 不要引入第三方依赖，`Package.swift` 保持没有 `dependencies`。

实现细节和设计取向见 [`TECHSHEET.md`](TECHSHEET.md)，结构说明见 [`STRUCTURE.md`](STRUCTURE.md)，
更多会踩坑的约定见 [`AGENTS.md`](AGENTS.md)。

## 贡献的授权

Lumi 以 [GPL-3.0](LICENSE) 发布。提交 PR 即表示：

- 这些代码是你自己写的，或者你有权以 GPL-3.0 提交它；
- 你同意你的贡献以 GPL-3.0 发布，**并且同意项目作者另以其他许可证分发包含你贡献的版本**
  （例如上架 Mac App Store 的版本）。

第二条是因为 GPL 与 App Store 的条款不兼容：没有这条授权，作者就不能把含有你代码的版本上架。
你的贡献在 GPL-3.0 下永远是开源的，这一点不受影响。
