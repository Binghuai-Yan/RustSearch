// Exercise the compiled Tauri WebView and real shared backend, in isolated data.
import { chromium, expect } from '@playwright/test';
import { spawn, execFileSync } from 'node:child_process';
import { mkdir, mkdtemp, readFile, realpath, writeFile } from 'node:fs/promises';
import { createServer } from 'node:net';
import { once } from 'node:events';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createInterface } from 'node:readline';

const frontend = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const repo = resolve(frontend, '..');
const executable = process.env.RUSTSEARCH_TEST_TAURI ?? join(frontend, 'src-tauri/target/debug/rustsearch-tauri.exe');
const temporary = await realpath(await mkdtemp(join(tmpdir(), 'rustsearch-tauri-test-')));
const root = join(temporary, '中文资料');
const data = join(temporary, 'data');
const artifacts = join(repo, 'artifacts', 'tauri');
await mkdir(root, { recursive: true });
await mkdir(artifacts, { recursive: true });
await writeFile(join(root, '采购合同.md'), '# 采购合同\n\n甲乙双方签订采购合同。\n\n项目编号：RS-2026\n交付时间：2026 年 10 月\n\n本文件用于验证中文全文搜索、预览与关键词高亮。\n\n所有文件均保存在本机。', 'utf8');
await writeFile(join(root, '安全预览.txt'), '<img src=x onerror="window.injected=true">\n<script>window.injected=true</script>\n安全预览与合同条款', 'utf8');
await Promise.all(Array.from({ length: 55 }, (_, i) => writeFile(join(root, `项目记录-${String(i + 1).padStart(2, '0')}.txt`), `项目记录 ${i + 1}\n检索验收 标准样本\n这是第 ${i + 1} 份本地文件。`, 'utf8')));

const server = createServer();
server.listen(0, '127.0.0.1');
await once(server, 'listening');
const port = server.address().port;
await new Promise((done) => server.close(done));
const appEnv = { ...process.env, RUSTSEARCH_DATA_DIR: data,
  RUSTSEARCH_PREFERENCES_DIR: join(temporary, 'preferences'),
  WEBVIEW2_USER_DATA_FOLDER: join(temporary, 'webview'),
  WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS: `--remote-debugging-port=${port} --remote-debugging-address=127.0.0.1` };
// Exercise discovery of the bundled Backend directory from an unrelated cwd.
delete appEnv.RUSTSEARCH_BACKEND_PATH;
const app = spawn(executable, [], { cwd: tmpdir(), windowsHide: true, env: appEnv });
let stderr = '';
app.stderr.on('data', (chunk) => { stderr += chunk.toString(); });
let browser, page, peer;
const failures = [];
try {
  // A fresh Windows runner may be initializing its WebView2 profile for the first time.
  for (let attempt = 0; attempt < 300; attempt++) {
    if (app.exitCode !== null) throw new Error(`Tauri exited: ${app.exitCode}\n${stderr}`);
    try { browser = await chromium.connectOverCDP(`http://127.0.0.1:${port}`); break; }
    catch { await new Promise((done) => setTimeout(done, 200)); }
  }
  if (!browser) throw new Error(`WebView debugging endpoint did not start.\n${stderr}`);
  for (let attempt = 0; attempt < 100; attempt++) {
    page = browser.contexts().flatMap((context) => context.pages())[0];
    if (page) break;
    await new Promise((done) => setTimeout(done, 100));
  }
  if (!page) throw new Error('Tauri did not create a WebView.');
  page.on('pageerror', (error) => failures.push(error.message));
  page.setDefaultTimeout(20000);
  const invoke = (method, params = {}) => page.evaluate(({ method, params }) => window.__TAURI_INTERNALS__.invoke('backend_call', { method, params }), { method, params });
  await expect(page.getByRole('heading', { name: '从一个文件夹开始' })).toBeVisible();
  await page.screenshot({ path: join(artifacts, 'first-run.png') });
  await page.getByRole('button', { name: '添加索引文件夹', exact: true }).click();
  await page.getByRole('textbox', { name: '文件夹路径' }).fill(root);
  await page.getByRole('button', { name: '添加', exact: true }).click();
  await expect(page.locator('.folder-info strong')).toHaveText(root);
  await expect.poll(async () => (await invoke('app.stats')).total_docs, { timeout: 60000 }).toBe(57);
  await expect.poll(async () => (await invoke('app.stats')).indexing, { timeout: 60000 }).toBe(false);
  await page.getByRole('button', { name: '刷新状态', exact: true }).click();
  await expect(page.locator('.folder-info span')).toHaveText('57 个文件');
  await page.screenshot({ path: join(artifacts, 'folders.png') });
  await page.getByRole('navigation').getByRole('button', { name: /文件搜索/ }).click();
  const input = page.getByRole('textbox', { name: '搜索文件', exact: true });
  await input.fill('"采购合同"');
  await expect(page.locator('.result-item')).toHaveCount(1);
  await expect(page.locator('.preview-text')).toContainText('甲乙双方签订采购合同');
  await expect(page.locator('.preview-text mark').first()).toBeVisible();
  await expect(page.locator('.result-title')).toHaveText('采购合同.md');
  await page.screenshot({ path: join(artifacts, 'search-light.png'), animations: 'disabled' });
  await page.getByRole('button', { name: '切换主题', exact: true }).click();
  await expect(page.locator('html')).toHaveAttribute('data-theme', 'dark');
  await page.screenshot({ path: join(artifacts, 'search-dark.png'), animations: 'disabled' });
  await page.getByRole('button', { name: '切换主题', exact: true }).click();
  await page.setViewportSize({ width: 920, height: 620 });
  await expect(page.locator('.preview-text')).toBeVisible();
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true);
  await page.screenshot({ path: join(artifacts, 'search-compact.png'), animations: 'disabled' });
  await page.setViewportSize({ width: 1280, height: 780 });

  await input.fill('检索验收');
  await expect(page.locator('.result-item')).toHaveCount(50);
  await page.getByRole('button', { name: '下一页', exact: true }).click();
  await expect(page.locator('.result-item')).toHaveCount(5);
  await expect(page.locator('.pagination')).toContainText('51–55 / 55');
  await page.getByRole('combobox', { name: '文件类型' }).selectOption('pdf');
  await expect(page.locator('.result-item')).toHaveCount(0);
  await page.getByRole('combobox', { name: '文件类型' }).selectOption('');
  await expect(page.locator('.result-item')).toHaveCount(50);
  await expect(page.locator('.pagination')).toContainText('1–50 / 55');

  await input.fill('"安全预览"');
  await expect(page.locator('.result-item')).toHaveCount(1);
  await expect(page.locator('.preview-text')).toContainText('<script>window.injected=true</script>');
  await expect(page.locator('.preview-text img, .preview-text script')).toHaveCount(0);
  expect(await page.evaluate(() => window.injected)).toBeUndefined();

  // Model the composition event sequence. Physical IME candidate windows require manual QA.
  await input.dispatchEvent('compositionstart');
  await input.fill('caigou');
  await new Promise((done) => setTimeout(done, 450));
  await expect(page.locator('.result-title')).toHaveText('安全预览.txt');
  await input.fill('"采购合同"');
  await input.dispatchEvent('compositionend');
  await expect(page.locator('.result-title')).toHaveText('采购合同.md');
  await input.fill('检索验收');
  await input.fill('"安全预览"');
  await expect(page.locator('.result-title')).toHaveText('安全预览.txt');

  await page.getByRole('navigation').getByRole('button', { name: '设置', exact: true }).click();
  const maxSize = page.getByRole('spinbutton', { name: '最大文件大小' });
  await maxSize.fill('100');
  await page.getByRole('button', { name: '保存索引设置', exact: true }).click();
  await expect(page.getByRole('status')).toContainText('设置已保存');
  expect((await invoke('config.get')).max_file_size_mb).toBe(100);
  await page.screenshot({ path: join(artifacts, 'settings.png') });
  await expect.poll(async () => (await invoke('app.stats')).indexing).toBe(false);
  await page.getByRole('navigation').getByRole('button', { name: /索引文件夹/ }).click();
  await page.getByRole('button', { name: '暂停索引', exact: true }).click();
  await expect(page.getByRole('button', { name: '恢复索引', exact: true })).toBeVisible();
  expect((await invoke('app.stats')).paused).toBe(true);
  await page.getByRole('button', { name: '恢复索引', exact: true }).click();
  await expect(page.getByRole('button', { name: '暂停索引', exact: true })).toBeVisible();
  await expect.poll(async () => (await invoke('app.stats')).indexing).toBe(false);
  // A second desktop client must reuse this engine; disconnecting our bridge
  // must not tear down another frontend's connection.
  peer = spawn(join(dirname(executable), 'Backend', 'rustsearch-backend.exe'), ['--connect'], {
    windowsHide: true, env: { ...process.env, RUSTSEARCH_DATA_DIR: data,
      RUSTSEARCH_BACKEND_PATH: join(dirname(executable), 'Backend', 'rustsearch-backend.exe') },
  });
  const peerPending = new Map();
  let peerId = 0;
  createInterface({ input: peer.stdout }).on('line', (line) => {
    const response = JSON.parse(line);
    if (peerPending.has(response.id)) {
      peerPending.get(response.id)(response);
      peerPending.delete(response.id);
    }
  });
  const peerCall = (method) => new Promise((resolve, reject) => {
    const id = ++peerId;
    const timer = setTimeout(() => { peerPending.delete(id); reject(new Error('Peer request timed out')); }, 20000);
    peerPending.set(id, (response) => { clearTimeout(timer); response.ok ? resolve(response.result) : reject(new Error(response.error.message)); });
    peer.stdin.write(`${JSON.stringify({ id, method, params: {} })}\n`);
  });
  const peerStats = await peerCall('app.stats');
  expect(peerStats.engine_pid).toBe((await invoke('app.stats')).engine_pid);
  expect(peerStats.active_clients).toBe(2);
  const bridgePid = Number(execFileSync('powershell.exe', ['-NoProfile', '-Command',
    `Get-CimInstance Win32_Process -Filter 'ParentProcessId = ${app.pid}' | Where-Object Name -eq 'rustsearch-backend.exe' | Select-Object -ExpandProperty ProcessId`,
  ], { encoding: 'utf8', windowsHide: true }).trim());
  expect(bridgePid).toBeGreaterThan(0);
  process.kill(bridgePid);
  await expect(page.locator('.engine-label')).toContainText('引擎未连接');
  await page.locator('.engine-card').getByRole('button', { name: '重新连接', exact: true }).click();
  await expect(page.locator('.engine-label')).toContainText('索引已就绪');
  expect((await peerCall('app.stats')).engine_pid).toBe(peerStats.engine_pid);
  const reconnectedBridge = Number(execFileSync('powershell.exe', ['-NoProfile', '-Command',
    `Get-CimInstance Win32_Process -Filter 'ParentProcessId = ${app.pid}' | Where-Object Name -eq 'rustsearch-backend.exe' | Select-Object -ExpandProperty ProcessId`,
  ], { encoding: 'utf8', windowsHide: true }).trim());
  process.kill(reconnectedBridge);
  await expect(page.locator('.engine-label')).toContainText('引擎未连接');
  await expect(page.locator('.engine-label')).toContainText('索引已就绪', { timeout: 30000 });
  expect((await peerCall('app.stats')).engine_pid).toBe(peerStats.engine_pid);
  // Shared desktop settings, MCP config, history and context actions.
  await page.getByRole('navigation').getByRole('button', { name: '设置', exact: true }).click();
  const desktop = await page.evaluate(() => window.__TAURI_INTERNALS__.invoke('desktop_settings'));
  expect(desktop.mcp_installed).toBe(true);
  expect(JSON.parse(desktop.claude).mcpServers.rustsearch.command.replace(/^\\\\\?\\/, "")).toBe(join(dirname(executable), 'Backend', 'rustsearch-mcp.exe'));
  expect(desktop.codex).toContain('[mcp_servers.rustsearch]');
  await page.getByRole('checkbox', { name: '关闭主窗口时最小化到托盘' }).uncheck();
  await expect.poll(async () => JSON.parse(await readFile(join(data, 'ui-preferences.json'), 'utf8')).CloseToTray).toBe(false);
  await page.getByRole('checkbox', { name: '关闭主窗口时最小化到托盘' }).check();
  await expect.poll(async () => JSON.parse(await readFile(join(data, 'ui-preferences.json'), 'utf8')).CloseToTray).toBe(true);
  expect((await readFile(join(data, 'ui-theme.txt'), 'utf8')).trim()).toBe('Light');

  const migrated = join(temporary, '迁移后的数据');
  await page.getByRole('textbox', { name: '新的数据目录' }).fill(migrated);
  await page.getByRole('button', { name: '更换数据目录', exact: true }).click();
  await page.getByRole('button', { name: '确认切换', exact: true }).click();
  await expect(page.getByRole('alert').first()).toContainText('Close MCP clients', { timeout: 60000 });
  expect((await peerCall('app.stats')).engine_pid).toBe(peerStats.engine_pid);
  peer.stdin.end();
  await once(peer, 'exit');
  peer = undefined;
  await expect.poll(async () => (await invoke('app.stats')).active_clients).toBe(1);

  // Cancel through the actual UI before copying, then reuse the same frontend.
  await page.getByRole('textbox', { name: '新的数据目录' }).fill(join(temporary, 'cancelled-data'));
  await page.getByRole('button', { name: '更换数据目录', exact: true }).click();
  await page.getByRole('button', { name: '确认切换', exact: true }).click();
  await page.getByRole('button', { name: '取消迁移', exact: true }).click();
  await expect(page.getByRole('alert').first()).toContainText('取消', { timeout: 60000 });
  expect((await invoke('app.stats')).data_directory).toBe(data);
  expect((await invoke('app.stats')).total_docs).toBe(57);

  // A non-empty destination must never be overwritten.
  const occupied = join(temporary, 'occupied');
  await mkdir(occupied);
  await writeFile(join(occupied, 'keep.txt'), 'preserve');
  await page.getByRole('textbox', { name: '新的数据目录' }).fill(occupied);
  await page.getByRole('button', { name: '更换数据目录', exact: true }).click();
  await page.getByRole('button', { name: '确认切换', exact: true }).click();
  await expect(page.getByRole('alert').first()).toContainText('不是空的', { timeout: 60000 });
  expect(await readFile(join(occupied, 'keep.txt'), 'utf8')).toBe('preserve');

  await page.getByRole('textbox', { name: '新的数据目录' }).fill(migrated);
  await page.getByRole('button', { name: '更换数据目录', exact: true }).click();
  await page.getByRole('button', { name: '确认切换', exact: true }).click();
  await expect(page.locator('.data-path')).toContainText(migrated, { timeout: 120000 });
  expect((await invoke('app.stats')).total_docs).toBe(57);
  expect(JSON.parse(await readFile(join(appEnv.RUSTSEARCH_PREFERENCES_DIR, 'ui-settings.json'), 'utf8')).data_directory).toBe(migrated);
  await expect(readFile(join(data, 'meta.db'))).rejects.toThrow();
  expect((await invoke('config.get')).max_file_size_mb).toBe(100);

  // Switch without copying and return to the already populated index.
  const empty = join(temporary, 'empty-data');
  await page.getByRole('checkbox', { name: '迁移现有索引和设置' }).uncheck();
  for (const [target, count] of [[empty, 0], [migrated, 57]]) {
    await page.getByRole('textbox', { name: '新的数据目录' }).fill(target);
    await page.getByRole('button', { name: '更换数据目录', exact: true }).click();
    await page.getByRole('button', { name: '确认切换', exact: true }).click();
    await expect(page.locator('.data-path')).toContainText(target, { timeout: 60000 });
    expect((await invoke('app.stats')).total_docs).toBe(count);
  }
  await page.getByRole('navigation').getByRole('button', { name: /文件搜索/ }).click();
  await page.getByRole('button', { name: '搜索历史', exact: true }).click();
  await expect(page.getByRole('dialog', { name: '搜索历史' })).toContainText('采购合同');
  await page.getByRole('dialog', { name: '搜索历史' }).getByRole('button', { name: '关闭', exact: true }).click();
  await input.fill('"采购合同"');
  await expect(page.locator('.result-item')).toHaveCount(1);
  await page.locator('.result-item').click({ button: 'right' });
  await expect(page.getByRole('dialog', { name: '文件操作' })).toBeVisible();
  await page.getByRole('dialog', { name: '文件操作' }).getByRole('button', { name: '复制路径', exact: true }).click();
  await expect(page.getByRole('status').first()).toContainText('已复制文件路径');
  await page.getByRole('navigation').getByRole('button', { name: /索引文件夹/ }).click();
  await page.getByRole('button', { name: '移除索引', exact: true }).click();
  await expect(page.getByRole('dialog')).toBeVisible();
  await page.getByRole('dialog').getByRole('button', { name: '移除索引', exact: true }).click();
  await expect(page.locator('.folder-row')).toHaveCount(0);
  expect(await readFile(join(root, '采购合同.md'), 'utf8')).toContain('采购合同');
  await expect(invoke('app.shutdown')).rejects.toThrow('不支持');
  expect(failures).toEqual([]);
  // Process.MainWindowHandle may return Tauri's auxiliary tray window.
  // Probe the actual main window by process ID and its configured title.
  const windowAction = (action) => execFileSync('powershell.exe', ['-NoProfile', '-ExecutionPolicy', 'Bypass',
    '-File', join(frontend, 'tests/window.ps1'), '-ApplicationPid', String(app.pid), '-Action', action],
    { encoding: 'utf8', windowsHide: true }).trim();
  windowAction('Close');
  await expect.poll(() => windowAction('Visible')).toBe('False');
  expect(app.exitCode).toBe(null);
  const second = spawn(executable, [], { cwd: tmpdir(), windowsHide: true, env: appEnv });
  await once(second, 'exit');
  expect(app.exitCode).toBe(null);
  await expect.poll(() => windowAction('Visible')).toBe('True');
  const exit = spawn(executable, ['--exit'], { cwd: tmpdir(), windowsHide: true, env: appEnv });
  await once(exit, 'exit');
  if (app.exitCode === null) await once(app, 'exit');
  expect(app.exitCode).toBe(0);
  await writeFile(join(artifacts, 'verification.json'), JSON.stringify({
    passed: true, checkedAt: new Date().toISOString(), executable,
    checks: ['isolated startup', 'Chinese path indexing', 'search and preview', 'safe highlighting',
      'pagination and filtering', 'composition events', 'latest query wins', 'light/dark themes', 'compact layout',
      'persistent settings', 'pause/resume', 'shared engine reuse', 'bridge disconnect and reconnect', 'automatic reconnect',
      'remove index preserves sources', 'RPC method allowlist', 'shared desktop preferences', 'MCP configuration',
      'migration refuses concurrent clients', 'migration refuses occupied destination', 'migration cancellation and recovery', 'verified data migration',
      'switch existing data directory', 'history access', 'context actions', 'tray close and restore', 'single instance and graceful exit'],
    fixtureDirectory: temporary,
  }, null, 2));
  console.log(`PASS: Tauri desktop checks. Screenshots: ${artifacts}`);
} catch (error) {
  if (page) {
    await page.screenshot({ path: join(artifacts, 'failure.png') }).catch(() => {});
    console.error((await page.locator('body').innerText().catch(() => '')).slice(0, 6000));
  }
  throw error;
} finally {
  if (browser) await browser.close().catch(() => {});
  app.kill();
  peer?.stdin.end();
  console.log(`Isolated fixtures retained: ${temporary}`);
}
