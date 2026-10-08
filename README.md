# RustSearch

[![Windows build](https://github.com/Binghuai-Yan/RustSearch/actions/workflows/windows-release.yml/badge.svg)](https://github.com/Binghuai-Yan/RustSearch/actions/workflows/windows-release.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

RustSearch 是完全本地运行的 Windows 全文搜索工具。WinUI 3 前端负责搜索、预览和设置；Rust sidecar 使用 Tantivy 建立索引，通过 stdin/stdout JSON Lines 与前端通信。文档和索引不会上传到服务器，程序运行时不需要联网。

![RustSearch 搜索界面](docs/screenshots/main-light.png)

## 下载与使用

从 [Releases](https://github.com/Binghuai-Yan/RustSearch/releases/latest) 下载 Windows x64 版本：

- `RustSearch-<版本>-win-x64-setup.exe`：安装版，提供开始菜单、可选桌面快捷方式和卸载入口。
- `RustSearch-<版本>-win-x64.zip`：便携版，解压后运行 `RustSearch.WinUI.exe`。请保留完整目录，不能只复制 EXE。

打开应用后，在设置的“索引文件夹”中添加目录，等待索引完成，再输入关键词搜索。点击结果可查看正文预览；双击打开文件，右键可打开所在文件夹或复制路径。Windows 10 1809 及以上版本、Windows 11 的 x64 桌面是目标平台；发布包包含 .NET 和 Windows App SDK 运行时。

## 功能

- 中文和英文全文搜索，300 ms 防抖；文件类型筛选、相关度/时间/大小排序、分页及最近搜索历史。
- 文件名、搜索片段和正文预览高亮；可拖动分隔条调整结果与预览宽度。
- 添加、移除、重建索引目录，暂停/恢复索引，文件变化自动更新。后台索引期间保留当前搜索结果和选中项，手动刷新后展示新结果。
- 浅色与深色主题、可选托盘驻留、自定义分词词典、忽略目录和最大文件大小设置。
- 可迁移索引和设置到新的数据文件夹；原目录保留作为备份。

支持纯文本、Markdown、常见代码和配置文件、CSV、HTML、PDF、DOCX、XLSX/XLS/XLSB、PPTX、EPUB。文本编码包括 UTF-8、GBK/GB18030 和 UTF-16。默认跳过隐藏目录、`.gitignore` 忽略项、常见依赖/构建目录、Office 临时文件及超过 200 MB 的文件。扫描版 PDF 暂不支持 OCR，旧版 `.doc` 和 `.ppt` 暂不支持。

搜索框支持以下语法：

| 示例 | 含义 |
| --- | --- |
| `合同 报价` | 匹配任一关键词 |
| `"采购合同"` | 精确短语 |
| `+合同 -过期` | 必含和排除词 |
| `合同 ext:pdf,docx` | 限定文件类型 |
| `size:>1mb` | 限定文件大小 |
| `date:>=2026-01-01` | 限定修改日期 |
| `path:C:\work\*` | 路径前缀 |

## 数据与卸载

默认数据目录是 `%LOCALAPPDATA%\RustSearch`，其中 `index/` 为 Tantivy 索引，`meta.db` 为 SQLite 元数据。设置中可更换数据目录并迁移现有索引。移除索引文件夹只删除对应搜索记录，不删除源文件。

安装版卸载时会询问是否删除当前用户的索引和元数据库，默认保留。选择删除只清理 `index/`、`meta.db` 及其 SQLite 附属文件，保留配置、词典和数据目录中的其他文件。静默卸载也默认保留；需要删除时显式传入 `/DELETEUSERINDEX`。

测试或独立部署可以设置 `RUSTSEARCH_DATA_DIR` 覆盖数据目录，使用 `RUSTSEARCH_PREFERENCES_DIR` 隔离保存目录选择的偏好。不要把个人索引数据加入源码仓库。

## 从源码构建

需要 Windows x64、PowerShell 7、Rust stable MSVC、Visual Studio C++ Build Tools 与 Windows SDK、.NET SDK 8 或更新版本，以及 Inno Setup 6。首次构建需要联网下载依赖。WinUI 自动化测试需要可交互的 Windows 桌面。

```powershell
./build.ps1
```

脚本运行 Rust 测试，发布自包含 WinUI 程序，执行桌面回归测试，并生成 `dist/` 下的便携 ZIP 和安装 EXE。非交互环境使用 `./build.ps1 -SkipUITests`，仍运行 Rust 测试；只生成 ZIP 可加 `-SkipInstaller`。完整安装、启动、卸载验收可用 `./build.ps1 -TestInstaller`。

依赖缓存默认位于可用的 `E:\cache\RustSearch-Dependencies`，否则位于用户本地应用数据目录；也可用 `RUSTSEARCH_DEPENDENCY_CACHE_DIR` 指定。它与应用索引数据分离。单独执行 Cargo 或 dotnet 命令前，可运行 `. ./scripts/use-dependency-cache.ps1` 采用相同缓存路径。

GitHub Actions 在 `main` 推送、拉取请求及手动触发时构建并上传 ZIP/EXE；推送 `v<版本>` 标签后，工作流还会创建 GitHub Release 并附上两个安装包。CI 跳过需要交互桌面的 UI 测试，本地发布前应运行完整桌面和安装器验收。

发布新版本时，先同步更新 `VERSION`、`rustsearch-backend/Cargo.toml` 和 `Cargo.lock` 中的版本并完成本地验收，再推送同版本的 `v<版本>` 标签。标签与 `VERSION` 不一致时，CI 会停止发布。

## 架构与许可

- `RustSearch.WinUI/`：WinUI 3 前端；`RustSearch.UI/` 保留 WPF 前端及两者共用的服务代码。
- `rustsearch-backend/`：文件提取、Tantivy 索引、SQLite 元数据、监听及 JSON Lines 协议。
- `installer/`、`build.ps1`：Inno Setup 安装包与发行构建。

项目代码采用 [MIT License](LICENSE)。随程序分发的 IconPark 图标属于字节跳动的 `@icon-park/svg`，采用 Apache-2.0，许可文本见 [IconPark LICENSE](RustSearch.WinUI/Assets/IconPark/LICENSE)。
