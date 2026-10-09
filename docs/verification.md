# 验证记录

本页保留早期里程碑的历史测试记录，部分路径、版本和当时的迁移行为已过时。当前版本的验证范围与结果见 [v0.1.6 更新记录](releases/v0.1.6.md)和[代码审查](review-2026-10.md)。

验证日期：2026-09-09，Windows x64。Rust 1.98.1、MSVC 14.44、.NET SDK 10.0.100 编译 net8.0-windows，.NET 8 Desktop Runtime 8.0.30。所有自动验证使用隔离临时目录，不索引用户现有文档。下表保留此前里程碑记录，本轮新增功能的回归状态单独列出。

| 里程碑 | 自动验证入口 | 状态 |
| --- | --- | --- |
| M0 协议 | scripts/test-m0.ps1 | PASS：stats、非法 JSON 恢复、shutdown、stdout 纯 JSON |
| M1 中文索引与搜索 | scripts/test-integration.ps1 | PASS：1003 个中文文件，索引约 3.43 秒，初次查询约 8 ms（Debug） |
| M2 文本提取 | cargo test --locked --offline | PASS：UTF-8/GB18030/UTF-16、中文 Office/EPUB/PDF、异常与截断 |
| M3 监听和增量 | scripts/test-integration.ps1 | PASS：文件与目录增改删/重命名、锁定恢复均 5 秒内；暂停恢复、重启扫描 |
| M4 WPF | dotnet build + scripts/test-ui.ps1 | PASS：125 个中文结果、快速输入取消、分页、预览、设置、紧凑窗口、托盘、单实例、崩溃重连 |
| M5 查询与恢复 | scripts/test-integration.ps1 | PASS：中英文短语、必含/排除、过滤排序、50 条历史、持久操作日志恢复、重叠根目录 |
| WinUI 启动修复 | scripts/test-winui.ps1 | PASS：已对 artifacts/winui-verified 自包含发布目录完成实际启动和交互验证，范围见下文 |
| WinUI 功能补齐 | scripts/test-winui-features.ps1 | PASS：原有功能回归通过；迁移新增断言因本机进程树权限限制未能重新执行 |
| Fluent 视觉回归 | scripts/test-winui-visual.ps1 | PASS：浅/深主题、主/设置标准与紧凑尺寸、五分类、控件边界、标题拖动和原生命中区域 |
| M6 最终发布 | dotnet publish --no-restore + 发布目录打包 | PASS：WinUI 3 自包含目录含 PRI、sidecar 与文档；ZIP SHA256 见交付记录 |

本轮 `cargo test --locked --offline`：26 项单元测试 + 2 项真实 PDF 子进程集成测试，共 28 项通过。

此前 `cargo clippy --all-targets --locked --offline -- -D warnings`：零警告。

PDF 集成样例包含会触发第三方库 stdout 诊断的 PDF 指令，验证主 sidecar 输出仍全部为合法 JSON Lines。

10 万文档 Release 基准（批量提交优化后）：索引 40.36 秒、索引目录 95.77 MB；4 组未缓存查询后端耗时 5-8 ms，缓存查询 2 ms 左右。优化前同规模索引为 319.65 秒，主要差异是从约 1000 次 Tantivy 提交和 6250 次 SQLite 事务降至大批次提交。定向监听在同一 100001 文档数据库新增文件耗时 2280.44 ms。基准数据为自动生成的短中英文 TXT，不能代替大型真实 Office/PDF 语料的性能测试。最新报告保存在 `artifacts/benchmark-100000-optimized.json`，原始报告在 `artifacts/benchmark-100000.json`；早期全目录监听失败记录保存在 `artifacts/watcher-100000-before-fix.json`，修复后已通过 `scripts/test-large-watcher.ps1`。

## WinUI 初始化错误修复

此前针对 `Microsoft.UI.Xaml` 初始化错误 `0xc000027b` 复现并修复了两个实际问题：

1. 编译输出存在应用 PRI，但 `dotnet publish` 没有将其复制到发布目录。项目增加 `EnableMsixTooling=true`，启用 SDK 内置的 PRI 发布目标；`WindowsPackageType=None` 仍为非 MSIX 发布。XBF 可以嵌入 PRI，不要求单独分发每个 XBF。
2. `App.xaml` 没有合并 `XamlControlsResources`，窗口使用的标准主题资源不可用。现已加载 WinUI 标准控件资源，并为初始化和未处理的 XAML 异常记录 `logs/winui-errors.log`。

同时修正窗口关闭顺序：先取消本次关闭，等待 Rust 后端停止后再关闭窗口，最后释放客户端和进程资源，避免窗口提前销毁导致清理中断。

实测对象为 `artifacts/winui-verified/RustSearch.WinUI.exe`，Windows App SDK 2.4.0、自包含 Windows x64 发布目录。测试从隔离工作目录启动，不依赖当前工作目录查找资源；数据与中文样例均在临时目录中生成。命令：

```powershell
./scripts/test-winui.ps1 -Executable ./artifacts/winui-verified/RustSearch.WinUI.exe
```

已通过的检查：

- 发布目录包含 `RustSearch.WinUI.pri`，实际创建可见 WinUI 窗口。
- 空数据目录冷启动，`app.stats` 返回零文档；通过子进程完整路径确认使用发布目录内的后端。
- 索引三份中文测试文档，搜索呈现三条结果，选择后显示中文预览；无命中查询返回零条。
- 浅色/深色切换后截图背景像素发生预期变化。
- 终止测试 sidecar 后自动重连，并重新完成搜索。
- 关闭窗口后 UI 正常退出且没有遗留 sidecar；再次启动能搜索持久化索引。
- 测试数据目录中未出现非空 `winui-errors.log`。

默认截图输出在 `artifacts/winui-smoke/`，包含首次启动、主题切换前后截图。脚本也会打印本次临时数据目录，便于检查日志。

`build.ps1` 已加入应用 PRI 缺失保护；默认 WinUI 构建会在压缩前运行启动烟测和 `scripts/test-winui-features.ps1`，因此需要可交互的 Windows 桌面。`-SkipTests` 跳过 Rust 测试和 UI 回归，但不会跳过 PRI 检查。

上述启动记录对应此前的发布目录，不能替代本轮新增功能或最终 ZIP 的验收。

## 本轮 WinUI 功能与回归范围

WinUI 当前已实现即时搜索、过期请求取消、文件类型筛选、相关度/时间/大小排序、分页、搜索历史、文件名和正文预览高亮、可调整宽度的结果/预览分隔条，以及打开文件、打开所在文件夹和复制路径等文件操作。完整设置包括索引文件夹增删和重建确认、统计、暂停/恢复、最大文件大小、忽略目录、自定义词典、主题和关闭行为。

浅色/深色主题可持久化，界面使用 IconPark 官方 `@icon-park/svg` 1.4.2 本地图标资源。关闭主窗口可选择完全退出或最小化到系统托盘，重复启动激活已有实例，`RustSearch.WinUI.exe --exit` 可请求已有实例退出。完全退出时取消设置中的待处理请求、文件夹选择和确认框；若目录切换尚未完成，会恢复原数据目录并停止后端。

设置中的索引目录和数据目录均支持直接填写完整路径或调用系统文件夹选择器。数据目录默认迁移当前索引、SQLite 元数据、配置、搜索历史和用户设置到新的空文件夹，迁移完成后可直接搜索；v0.1.5 起，验证新目录成功后会清理原目录中的已迁移索引和配置，失败或取消时恢复原目录。取消迁移选项时可直接使用目标目录已有的数据。

全功能回归入口：

```powershell
./scripts/test-winui-features.ps1 -Executable ./dist/RustSearch/RustSearch.WinUI.exe
```

此前对 `artifacts/fluent-publish/RustSearch.WinUI.exe` 的真实窗口回归已通过原有功能，迁移实现已完成编译；本轮迁移新增断言因本机 UI 测试脚本查询进程树被系统拒绝，未能重新启动桌面回归。覆盖范围包括：

- 从 UI 添加测试文件夹并建立索引，中文即时搜索、快速输入取消、过滤、排序、分页、短语查询、预览及复制路径。
- 键盘和鼠标调整分隔条、浅深主题的截图像素变化、紧凑主窗口控件边界。
- 保存索引设置、暂停/恢复、重建与移除确认、取消移除后保持索引、移除后保留源文件。
- 数据目录切换回滚、在新目录下重复启动和 `--exit`；迁移代码另有逐文件校验和源目录保留逻辑，待具备进程树访问权限的桌面环境执行新增迁移断言。
- 托盘关闭、单实例激活、后端崩溃恢复、`--exit`、持久化索引重启、关闭即退出，以及确认框未回答时完全退出。

本轮通过的截图在 `artifacts/fluent-features/`；视觉截图和尺寸记录在 `artifacts/fluent-visual-final/`。自动测试通过 `RUSTSEARCH_DATA_DIR` 隔离索引数据，通过 `RUSTSEARCH_PREFERENCES_DIR` 隔离保存目录选择的 UI 偏好和单实例作用域，不修改用户全局配置。启动时显式 `RUSTSEARCH_DATA_DIR` 优先于保存的目录选择；只有数据目录覆盖时，偏好存储也落在该隔离目录内。

本轮后端端到端回归已通过原有 `scripts/test-integration.ps1` 的全部断言：1003 个中文文件首次索引约 0.46 秒，首次查询约 4 ms；高级查询、文件与目录增改删/重命名、独占锁恢复、暂停/恢复、重启持久化、崩溃恢复和重叠根目录均通过，实时更新仍按 5 秒期限验收。修复了首次索引完成早于文件监听注册时的变更遗漏：新根目录注册监听后立即做一次增量核对。`cargo test --locked` 的 28 项测试和 `cargo fmt --check` 均通过。

最终 0.1.2 ZIP 已由自包含 `dotnet publish --no-restore` 发布并打包于 `dist/RustSearch-0.1.2-win-x64.zip`；其内容来自同一套通过真实 UI 回归的自包含发布。视觉验收在 120 DPI 下记录标准窗口 1180x820 和紧凑窗口 1000x775（主窗口）、750x700（设置窗口）的实际像素尺寸。

运行测试范围为当前 Windows 本机上的真实发布程序，尚未在未安装开发依赖的干净虚拟机上验证。WinUI 界面使用原生 WinUI 控件，Windows Forms 框架引用仅用于托盘；自包含发布仍应以目标机器上的运行结果确认兼容性。
