# RustSearch Tauri

独立的 Windows 桌面前端，使用 Tauri 2、Vue 3、TypeScript 和系统 WebView2。通过 `rustsearch-backend.exe --connect` 接入现有共享引擎，索引、搜索历史、OCR 和后端设置与 WinUI/WPF 共用。

## 启动

需要 Windows x64、PowerShell 7、Node.js 22.12+（推荐 Node.js 24 LTS）、Rust stable MSVC、Visual Studio C++ Build Tools / Windows SDK 、.NET 8 SDK 和 WebView2 Runtime。

在仓库根目录执行：

```powershell
cd RustSearch.Tauri
npm ci
npm run desktop
```

脚本采用仓库的 Cargo 依赖缓存，先构建现有后端，再启动 Vite 和 Tauri。首次构建需要下载依赖；应用运行时无需联网。开发服务仅监听 `127.0.0.1:5173`。

`npm run dev` 仅启动网页开发服务器，不连接本地引擎；桌面功能请使用 `npm run desktop`。

默认沿用当前用户的 RustSearch 数据目录，也遵循 `RUSTSEARCH_DATA_DIR`、`RUSTSEARCH_PREFERENCES_DIR` 和 `RUSTSEARCH_BACKEND_PATH`。测试时建议隔离目录：

```powershell
$env:RUSTSEARCH_DATA_DIR = Join-Path $env:TEMP 'RustSearch-Tauri-Sandbox'
$env:RUSTSEARCH_PREFERENCES_DIR = Join-Path $env:TEMP 'RustSearch-Tauri-Preferences'
npm run desktop
```

## 当前功能

- 300 ms 防抖搜索，中文输入法组词期间不查询，忽略过期响应；文件类型、相关度/日期/大小排序和每页 50 条结果。
- 文件名与摘要高亮、纯文本预览、正文关键词高亮、可拖动分隔条、默认程序打开文件、定位文件夹、复制路径。
- 添加、移除、重建索引目录，暂停/恢复、索引状态和进度。索引更新只提示刷新，保留当前结果；移除目录不会删除源文件。
- 共享的浅色/深色主题，文件大小限制、忽略目录、自定义分词词典、OCR 开关、文件类型与 PDF 页数限制、失败重试。
- `Ctrl+K` 聚焦搜索、搜索语法帮助、连接错误提示与手动重连。

原生窗口提供拖动、缩放及系统关闭按钮，默认关闭到托盘，可在设置中改为退出；托盘和 `--exit` 支持完全退出，重复启动会激活已有窗口。支持搜索历史、结果右键操作、MCP 状态和配置复制、数据目录迁移/切换及迁移取消。迁移复用 WinUI/WPF 的 C# 校验代码，通过随包的自包含 `RustSearch.MigrationHost.exe` 执行，用户无需安装 .NET；这会增加发行体积。复制经过 SHA-256 校验，新索引验证成功后才清理旧索引，失败回滚；其他前端或 MCP 客户端仍连接时拒绝迁移。WebView2 的微信输入法候选窗仍需物理输入法手动验收。

预览最多渲染 250,000 个字符，超过时显示提示并可打开原文件。文档内容始终作为文本渲染，后端 `<b>` 标记会拆分为 Vue 文本与 `mark` 节点，不使用 `v-html`。

## 构建

正式发布请在仓库根目录运行 `./build.ps1`，同时生成三套独立 ZIP 和 Inno Setup 安装器。只编译 Tauri 发行包可使用 `./build.ps1 -Frontend Tauri`。三套版本、共享资源和功能约定见 [frontend-parity.md](../docs/frontend-parity.md)。以下原生 Tauri 构建命令用于开发调试：

```powershell
npm run desktop:build
```

生成 `src-tauri/target/release/rustsearch-tauri.exe` 和 `src-tauri/target/release/bundle/nsis/` 下的安装包。安装包携带搜索后端及 OCR 运行时；首次安装如果系统缺少 WebView2，Tauri 安装程序会按默认策略下载运行时。

只构建可执行目录，不生成安装包：

```powershell
npm run desktop:build -- -NoBundle
```

分发非安装版时，必须一并保留可执行程序旁的 `Backend/` 目录。`-SkipOcr` 可跳过 OCR 运行时准备，适合只验证文本搜索；这种构建不保证 OCR 可用。开发模式会优先使用 `RUSTSEARCH_OCR_RUNTIME_DIR`，否则尝试复用 `../dist/RustSearch-WinUI/Backend/OCR`。

## 验证

```powershell
npm run build
npm test
```

桌面回归需要先构建包含本地网页资源的 Debug 程序（不要使用 Vite 开发地址）：

```powershell
./scripts/desktop.ps1 -PrepareOnly
# 当前终端需能找到 cargo；也可把用户 .cargo/bin 加入 PATH。
npm run tauri -- build --debug --no-bundle
npm run test:desktop
```

回归使用真实 Tauri WebView、真实共享后端和临时索引目录，不依赖安装 Playwright 浏览器。测试专用 WebView2 调试端口仅监听本机；普通启动不启用调试端口。报告与截图保存在仓库的 `artifacts/tauri/`，临时样例保留以便排查。`RUSTSEARCH_TEST_TAURI` 可指定其他已打包资源的可执行文件。模拟 composition 事件不等于物理输入法候选窗测试。

初版验证记录（新增功能以当前回归报告为准）：前端类型检查与构建通过；Rust `fmt`、`clippy --all-targets --locked -- -D warnings` 通过；3 项高亮安全单元测试通过。Debug 和独立运行目录中的 Release 程序均完成 15 项桌面回归，包括 37 个中文路径样例的索引、搜索/预览、分页/筛选、浅深主题、紧凑布局、组词事件、过期查询保护、设置保存、暂停/恢复、共享引擎复用、桥接断线重连及移除索引保留源文件。Release 验收从临时工作目录启动，不设置后端路径覆盖，验证随附资源查找。

## 结构

- `src/`：Vue 界面、搜索状态管理与带类型的调用封装。
- `src-tauri/src/backend.rs`：共享后端子进程桥接、请求编号、超时清理和事件转发。
- `src-tauri/capabilities/main.json`：主窗口只申请事件和文件夹选择权限；文件打开由受控 Rust 命令完成。
- `scripts/desktop.ps1`：后端准备、OCR 资源与桌面开发/打包。
- `tests/`：高亮安全测试和真实桌面回归。

当前只验收 Windows。共享后端使用 Windows 命名管道，尚不能直接将这个前端当作已支持 macOS/Linux 的发行版。
