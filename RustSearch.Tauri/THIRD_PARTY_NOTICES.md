# Tauri 前端第三方组件

本前端自有代码沿用仓库 MIT 许可。现有搜索引擎及 OCR 的许可见仓库根目录 `THIRD_PARTY_NOTICES.md` 和随包 `Backend/OCR` 中的许可文本。

前端新增的直接运行时依赖：

| 组件 | 项目 | 许可 |
| --- | --- | --- |
| Tauri、tauri-build、@tauri-apps/api、CLI | https://github.com/tauri-apps/tauri | MIT OR Apache-2.0 |
| Tauri dialog、opener、single-instance 插件 | https://github.com/tauri-apps/plugins-workspace | MIT OR Apache-2.0 |
| .NET 8 自包含迁移组件运行时 | https://github.com/dotnet/runtime | MIT |
| Vue | https://github.com/vuejs/core | MIT |
| Lucide | https://github.com/lucide-icons/lucide | ISC |
| Tokio | https://github.com/tokio-rs/tokio | MIT |
| Serde、serde_json | https://github.com/serde-rs | MIT OR Apache-2.0 |
| Microsoft Edge WebView2 | https://developer.microsoft.com/microsoft-edge/webview2/ | Microsoft WebView2 分发条款 |

开发工具包括 Vite、Vue Vite 插件、Vitest、TypeScript、vue-tsc 与 Playwright。精确依赖版本分别锁定于 `package-lock.json` 和 `src-tauri/Cargo.lock`；各依赖包保留原始许可。本文件是直接依赖说明，不替代完整发行许可审计。
