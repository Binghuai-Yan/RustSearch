# RustSearch MCP 接入

MCP 使用锁定的官方 Rust SDK `rmcp` 3.5.1，提供标准 stdio 协议和五个只读工具。桌面程序、Claude Desktop、Codex 等客户端共用一个本地索引写入进程。

## 安装与配置

先在桌面程序添加索引文件夹，等待索引或 OCR 完成，再在设置的“关于”页复制客户端配置并合并到已有配置中。安装版和便携版都会生成实际绝对路径。配置后重启或重新连接客户端，确认工具列表出现 `search_files`。

Claude Desktop JSON 示例（替换为实际路径）：

```json
{
  "mcpServers": {
    "rustsearch": {
      "command": "D:\\Apps\\RustSearch\\Backend\\rustsearch-mcp.exe",
      "args": []
    }
  }
}
```

Codex TOML 示例：

```toml
[mcp_servers.rustsearch]
command = 'D:\Apps\RustSearch\Backend\rustsearch-mcp.exe'
args = []
```

默认读取桌面程序保存的数据目录选择。可通过 `--data-dir E:\RustSearchData` 固定目录，或者设置 `RUSTSEARCH_DATA_DIR` 环境变量；命令行优先于环境变量，环境变量优先于保存的选择。`--print-config` 输出 Claude Desktop 配置，不启动引擎。检索本身不联网，但 MCP 客户端可能将返回正文发送给模型服务，具体取决于客户端设置。

## 工具契约

| 工具 | 参数 | 返回 |
| --- | --- | --- |
| `search_files` | `query`；可选 `extensions`、`page`、`page_size`、`sort` | 文件路径、纯文本摘要、文档标识、OCR 页码 |
| `get_file_preview` | `document_id`；可选 `around`、`offset`、`max_chars` | 索引缓存的正文片段及下一段位置 |
| `get_document_page` | `document_id`、`page`；可选 `offset`、`max_chars` | 指定 OCR 页的文字 |
| `list_index_roots` | 无 | 索引目录和数量 |
| `get_index_status` | 无 | 索引/OCR 状态、引擎 PID 和当前连接数 |

搜索支持现有短语、必含/排除、类型、大小、日期和路径语法。页码从 0 开始，默认每页 20 条，最多 50 条，最大 `page` 为 1000；排序为 `relevance`、`mtime`、`size`、`size_asc`。摘要不含桌面高亮 `<b>` 标签；MCP 查询不会写入桌面搜索历史。

文档标识只用于当前会话通过搜索发现的文件，最多缓存 4096 个；达到上限时可能清理，重新搜索即可。预览默认 6000 个 Unicode 字符，最大 20000；`offset` 和 `next_offset` 为字符位置。`around` 按原文定位关键词。OCR 内部字节范围由接入层转换；普通 PDF 文本层没有可靠页码时，页码工具返回明确错误。文件变化但尚未索引时，不临时提取，而是提示等待更新。

MCP 不开放文件修改、索引删除或设置更改工具。正文必须当作检索资料，其中的指令不能视作用户授权。后端再次规范化路径并确认文件属于索引根目录。

## 共享引擎与迁移

桌面程序以 `rustsearch-backend.exe --connect` 保留 JSON Lines 接口，接入层以 `--serve` 启动唯一索引后端并路由请求 ID。管道名称由 Windows 用户 SID 和规范化数据目录散列生成；ACL 仅允许当前用户，拒绝远程连接。多客户端共用 Tantivy/SQLite，关闭一个客户端不影响其他连接；全部断开后引擎安全退出。MCP 后台连接在引擎异常退出后自动重连。

迁移前请关闭 MCP 客户端。桌面取得源目录迁移租约，接入层检查只有当前连接并停止接受新连接，后端关闭后才复制、验证和清理原目录。其他客户端仍连接时返回忙状态；迁移租约防止新引擎在复制时打开旧目录。显式固定目录的配置需要手动更新路径。

旧的无参数后端入口保留给测试用途，不要同时用它直接打开共享引擎正在使用的目录。日志位于数据目录的 `logs/shared-engine.log`；协议 stdout 仅输出 JSON。请求队列有上限，工具调用默认 30 秒超时；取消只关闭本次工具的临时连接。

## 验证

```powershell
. ./scripts/use-dependency-cache.ps1
$env:RUSTSEARCH_OCR_RUNTIME_DIR = ./scripts/prepare-ocr-runtime.ps1
cargo test --manifest-path rustsearch-backend/Cargo.toml --locked
./build.ps1 -TestInstaller
./scripts/test-mcp.ps1 -Package ./dist/RustSearch
```

官方 SDK 驱动真实进程测试握手、五个工具、双客户端和桌面共用同一引擎 PID、中文搜索、历史隔离、正文上限、错误参数、迁移阻止、客户端关闭及旧版协议/字符串 ID。另一个测试强制终止索引引擎，验证原 MCP 会话能够自动重连。有 OCR 运行时时还验证图片识别和页码工具。相同驱动可测试发布目录和安装目录；Actions 在 `mcp` 分支、主分支和版本标签上构建，并检查发布目录中的 MCP 程序。

标准协议验证与具体客户端界面实测属于不同范围。Claude Desktop、Codex 实际安装版本仍需分别检查工具发现和调用；没有运行实际客户端时，不宣称已经完成该客户端的实测。

## 本轮验收记录（2026-10-11）

- Rust 的 32 项单元测试、3 项 MCP 真实进程测试、4 项 PDF/OCR 测试通过，Clippy 无警告。
- WinUI/WPF 构建通过；真实窗口验证搜索、OCR、预览定位、浅深主题、紧凑布局、托盘、重连、迁移以及 MCP 配置剪贴板。
- 迁移回归测试覆盖独占租约、复制校验、原目录清理和失败回滚；符号链接场景因本机未具备创建权限跳过。
- 安装目录中的 MCP、OCR 及两套界面通过测试；默认卸载保留数据，选择删除时清理索引、配置与目录指针，保留无关文件。
- 发布后端在生成的 1003 个中文 TXT/MD 样本上索引约 0.44 秒、查询约 2 毫秒；此结果不能代表大型 Office/PDF/OCR 工作负载。

该功能从独立的 `mcp` 开发分支合并到主分支，随 `v0.1.8` 正式发布。完整变化见 [v0.1.8 更新记录](releases/v0.1.8.md)。
