<script setup lang="ts">
import { computed, nextTick, onBeforeUnmount, onMounted, ref, watch } from 'vue';
import { invoke, isTauri } from '@tauri-apps/api/core';
import { listen, type UnlistenFn } from '@tauri-apps/api/event';
import { open } from '@tauri-apps/plugin-dialog';
import { ArrowDownUp, ArrowUpRight, Check, ChevronLeft, ChevronRight, CircleHelp, Copy, File,
  FileCode2, FileImage, FileSpreadsheet, FileText, Folder, FolderOpen, FolderPlus, HardDrive,
  LoaderCircle, Moon, Pause, Play, Plus, RefreshCw, Search, Settings2, ShieldCheck, Sun,
  Trash2, X } from 'lucide-vue-next';
import { FILE_FILTERS, PAGE_SIZE, bytes, call, date, errorText, openPath, type Config, type Root, type DesktopSettings, type Hit } from './api';
import { snippetParts } from './highlight';
import HighlightedText from './components/HighlightedText.vue';
import { useSearch } from './useSearch';
import { version } from '../package.json';

const { connected, connecting, error, notice, stats, roots, config, history, progress, updated,
  query, extension, sort, page, composing, searching, result, selected, preview, migrating,
  previewLoading, previewError, previewElement, pageCount, previewText, select, search,
  changePage, refreshStatus, connect, action } = useSearch();
const view = ref<'search' | 'folders' | 'settings'>('search');
const searchInput = ref<HTMLInputElement>();
const pathInput = ref(''), busy = ref(false), removeTarget = ref<Root>();
const removeDialog = ref<HTMLDialogElement>();
const helpDialog = ref<HTMLDialogElement>();
const settings = ref<Config>(), skipDirs = ref('');
const theme = ref('light');
const desktop = ref<DesktopSettings>();
const closeToTray = ref(true), targetData = ref(''), migrateData = ref(true);
const migrationDialog = ref<HTMLDialogElement>(), historyDialog = ref<HTMLDialogElement>();
const migrationProgress = ref(''), contextHit = ref<Hit>();
const contextDialog = ref<HTMLDialogElement>();
let stopProgress: UnlistenFn | undefined;
const dark = ref(false);
const media = window.matchMedia('(prefers-color-scheme: dark)');
const split = ref(47), workspace = ref<HTMLElement>();
const status = computed(() => !connected.value ? '引擎未连接' : stats.value?.paused ? '索引已暂停' : stats.value?.indexing ? '正在建立索引' : '索引已就绪');
const progressPercent = computed(() => progress.value?.total ? Math.round(progress.value.done / progress.value.total * 100) : 0);
const filters = FILE_FILTERS;
function iconFor(ext: string) {
  if (['png', 'jpg', 'jpeg', 'bmp', 'tif', 'tiff'].includes(ext)) return FileImage;
  if (['xlsx', 'xls', 'xlsb', 'csv'].includes(ext)) return FileSpreadsheet;
  if (['rs', 'py', 'js', 'ts', 'cs', 'json', 'html', 'css'].includes(ext)) return FileCode2;
  return FileText;
}
function applyTheme() {
  dark.value = theme.value === 'system' ? media.matches : theme.value === 'dark';
  document.documentElement.dataset.theme = dark.value ? 'dark' : 'light';

}
function toggleTheme() { void setTheme(dark.value ? 'light' : 'dark'); }
watch(theme, applyTheme, { immediate: true });
watch(config, (value) => {
  if (value) { settings.value = { ...value, skip_dirs: [...value.skip_dirs] }; skipDirs.value = value.skip_dirs.join('\n'); }
});
watch(view, (value) => {
  notice.value = '';
  if (value === 'settings' && connected.value) {
    void loadDesktop();
    void call<Config>('config.get').then((value) => { config.value = value; }).catch((err) => { error.value = errorText(err); });
  }
});
async function run(task: () => Promise<unknown>) {
  if (busy.value) return;
  busy.value = true; error.value = ''; notice.value = '';
  try { await task(); } catch (err) { error.value = errorText(err); }
  finally { busy.value = false; }
}
async function browse() {
  await run(async () => {
    const folder = await open({ directory: true, multiple: false, title: '选择索引文件夹' });
    if (typeof folder === 'string') pathInput.value = folder;
  });
}
async function addRoot() {
  const path = pathInput.value.trim();
  if (!path) return;
  await run(async () => {
    await action('index.add_root', { path }, '文件夹已添加，索引将在后台建立。');
    pathInput.value = '';
  });
}
async function askRemove(root: Root) {
  removeTarget.value = root;
  await nextTick();
  removeDialog.value?.showModal();
}
async function removeRoot() {
  const root = removeTarget.value;
  if (!root) return;
  removeDialog.value?.close();
  await run(async () => {
    await action('index.remove_root', { path: root.path }, '已移除搜索索引，源文件仍保留在原位置。');
    await search();
  });
}
async function saveSettings() {
  if (!settings.value) return;
  await run(async () => {
    const value = settings.value!;
    // Do not patch paused: another frontend can pause indexing independently.
    config.value = await action('config.set', {
      max_file_size_mb: value.max_file_size_mb,
      skip_dirs: skipDirs.value.split(/\r?\n/).map((s) => s.trim()).filter(Boolean),
      user_dictionary: value.user_dictionary,
      ocr_enabled: value.ocr_enabled, ocr_images: value.ocr_images,
      ocr_pdf: value.ocr_pdf, ocr_max_pages: value.ocr_max_pages,
    }, '设置已保存，受影响的文件将在后台重新处理。') as Config;
  });
}
async function copyPath() {
  if (selected.value) await run(async () => { await navigator.clipboard.writeText(selected.value!.path); notice.value = '已复制文件路径。'; });
}
async function loadDesktop() {
  if (!isTauri()) return;
  try {
    desktop.value = await invoke<DesktopSettings>('desktop_settings');
    theme.value = desktop.value.theme === 'dark' ? 'dark' : 'light';
    closeToTray.value = desktop.value.close_to_tray;
  } catch (err) { error.value = errorText(err); }
}
async function saveDesktop() {
  await run(() => invoke('save_desktop_settings', { theme: theme.value, closeToTray: closeToTray.value }));
}
async function setTheme(value: string) { theme.value = value; await saveDesktop(); }
async function copyMcp(kind: 'claude' | 'codex') {
  await run(async () => { if (desktop.value) await navigator.clipboard.writeText(desktop.value[kind]); notice.value = '配置已复制，请合并到客户端现有 MCP 配置中。'; });
}
async function browseData() {
  await run(async () => { const path = await open({ directory: true, multiple: false, title: '选择数据目录' }); if (typeof path === 'string') targetData.value = path; });
}
async function changeData() {
  migrationDialog.value?.close();
  await run(async () => {
    migrating.value = true; migrationProgress.value = '正在停止引擎，准备切换目录…';
    let failure: unknown;
    try {
      const result = await invoke<{ warning?: string }>('change_data_directory', { destination: targetData.value.trim(), migrate: migrateData.value });
      notice.value = result.warning ?? (migrateData.value ? '迁移完成，已切换到新目录。' : '已切换数据目录，原数据保留。');
      targetData.value = '';
    } catch (err) { failure = err; }
    finally { migrating.value = false; migrationProgress.value = ''; page.value = 0; await connect(); await loadDesktop(); }
    if (failure) throw failure;
  });
}
async function showHistory() {
  await run(async () => { history.value = (await call<{ queries: string[] }>('search.history')).queries; historyDialog.value?.showModal(); });
}
async function showContext(hit: Hit) { contextHit.value = hit; await select(hit); contextDialog.value?.showModal(); }
function shortcut(event: KeyboardEvent) {
  if ((event.ctrlKey || event.metaKey) && event.key.toLowerCase() === 'k') {
    event.preventDefault(); view.value = 'search';
    void nextTick(() => { searchInput.value?.focus(); searchInput.value?.select(); });
  }
}
function resize(event: PointerEvent) {
  const handle = event.currentTarget as HTMLElement;
  handle.setPointerCapture(event.pointerId);
}
function moveSplit(event: PointerEvent) {
  if (!(event.currentTarget as HTMLElement).hasPointerCapture(event.pointerId)) return;
  const rect = workspace.value!.getBoundingClientRect();
  split.value = Math.min(65, Math.max(33, (event.clientX - rect.left) / rect.width * 100));
}
onMounted(async () => {
  document.addEventListener('keydown', shortcut); media.addEventListener('change', applyTheme);
  await loadDesktop();
  if (isTauri()) stopProgress = await listen<{ CopiedBytes: number; TotalBytes: number; CopiedFiles: number; TotalFiles: number }>('migration-progress', ({ payload: p }) => {
    migrationProgress.value = `正在复制并校验 · ${bytes(p.CopiedBytes)} / ${bytes(p.TotalBytes)} · ${p.CopiedFiles}/${p.TotalFiles} 个文件`;
  });
});
onBeforeUnmount(() => { stopProgress?.(); document.removeEventListener('keydown', shortcut); media.removeEventListener('change', applyTheme); });
</script>

<template>
  <div class="app-shell">
    <aside class="sidebar">
      <div class="brand"><span class="brand-icon"><Search :size="22" :stroke-width="2.7" /></span><div>RustSearch<span>让本地文件，即搜即得</span></div></div>
      <div class="nav-label">工作空间</div>
      <nav aria-label="主导航" :inert="migrating">
        <button :class="{ active: view === 'search' }" @click="view = 'search'"><Search :size="18" />文件搜索<kbd>Ctrl K</kbd></button>
        <button :class="{ active: view === 'folders' }" @click="view = 'folders'"><FolderOpen :size="18" />索引文件夹<span class="nav-count">{{ roots.length }}</span></button>
        <button :class="{ active: view === 'settings' }" @click="view = 'settings'"><Settings2 :size="18" />设置</button>
      </nav>
      <div class="sidebar-bottom">
        <div class="engine-card">
          <div class="engine-label"><span class="status-dot" :class="{ offline: !connected, working: stats?.indexing }"></span>{{ status }}</div>
          <strong>{{ (stats?.total_docs ?? 0).toLocaleString() }}<span> 个文件</span></strong>
          <div v-if="progress" class="small-progress"><span :style="{ width: `${progressPercent}%` }"></span></div>
          <p>{{ connected ? `${bytes(stats?.index_size_bytes ?? 0)} · ${roots.length} 个文件夹` : '连接后即可搜索本地文件' }}</p>
          <button v-if="!connected" class="text-button" :disabled="connecting" @click="connect"><RefreshCw :size="13" :class="{ spinning: connecting }" />{{ connecting ? '正在连接…' : '重新连接' }}</button>
        </div>
        <div class="privacy"><ShieldCheck :size="14" />完全本地 · 文件无需上传</div>
      </div>
    </aside>

    <main>
      <header class="topbar">
        <div class="breadcrumb">工作空间<ChevronRight :size="13" /><strong>{{ view === 'search' ? '文件搜索' : view === 'folders' ? '索引文件夹' : '设置' }}</strong></div>
        <div class="top-actions"><button class="icon-button" title="搜索语法" aria-label="搜索语法" @click="helpDialog?.showModal()"><CircleHelp :size="18" /></button><button class="icon-button" :title="dark ? '切换浅色主题' : '切换深色主题'" aria-label="切换主题" @click="toggleTheme"><Sun v-if="dark" :size="18" /><Moon v-else :size="18" /></button></div>
      </header>
      <div v-if="error" role="alert" class="banner error"><span>{{ error }}</span><button class="icon-button" aria-label="关闭错误提示" @click="error = ''"><X :size="16" /></button></div>
      <div v-if="notice" role="status" class="banner success"><Check :size="16" /><span>{{ notice }}</span><button class="icon-button" aria-label="关闭提示" @click="notice = ''"><X :size="16" /></button></div>

      <section v-show="view === 'search'" class="search-page">
        <div class="search-heading"><div><h1>搜索你的文件</h1><p>从文件名到正文，找到你需要的那一处。</p></div><button class="secondary" @click="view = 'folders'"><FolderPlus :size="16" />添加文件夹</button></div>
        <form class="search-box" role="search" @submit.prevent="!composing && search()">
          <Search :size="21" /><input ref="searchInput" v-model="query" aria-label="搜索文件" placeholder="输入关键词，搜索文件名或正文…" maxlength="1000" autocomplete="off" spellcheck="false" @compositionstart="composing = true" @compositionend="composing = false" />
          <LoaderCircle v-if="searching" :size="19" class="spinning" /><button v-else-if="query" class="icon-button" type="button" aria-label="清空搜索" @click="query = ''; searchInput?.focus()"><X :size="17" /></button><kbd v-else>Ctrl K</kbd>
        </form>
        <div class="filter-row">
          <div class="select-wrap"><File :size="15" /><select v-model="extension" aria-label="文件类型"><option v-for="filter in filters" :key="filter.value" :value="filter.value">{{ filter.label }}</option></select></div>
          <div class="select-wrap"><ArrowDownUp :size="15" /><select v-model="sort" aria-label="排序方式"><option value="relevance">相关度优先</option><option value="mtime_desc">最近修改</option><option value="size_desc">文件从大到小</option><option value="size_asc">文件从小到大</option></select></div>
          <button class="text-button" :disabled="!connected || busy" @click="showHistory">搜索历史</button><span class="filter-spacer"></span><button class="text-button" :disabled="!connected || searching" @click="search"><RefreshCw :size="14" />{{ updated ? '索引有更新，刷新结果' : '刷新' }}</button>
        </div>

        <div v-if="!roots.length && connected" class="empty-state welcome">
          <div class="empty-icon"><FolderPlus :size="32" /></div><h2>从一个文件夹开始</h2><p>添加常用的文档目录，建立索引后即可搜索文件内容。<br />支持 PDF、Office、文本、代码及图片中的文字。</p><button class="primary" @click="view = 'folders'"><Plus :size="17" />添加索引文件夹</button><span class="empty-note"><ShieldCheck :size="13" />文件和索引始终保存在这台电脑上</span>
        </div>
        <div v-else-if="!connected" class="empty-state"><div class="empty-icon"><HardDrive :size="30" /></div><h2>{{ connecting ? '正在连接本地引擎' : '等待连接本地引擎' }}</h2><p>连接成功后，即可搜索已索引的文件。</p><button class="primary" :disabled="connecting" @click="connect"><RefreshCw :size="16" :class="{ spinning: connecting }" />{{ connecting ? '连接中…' : '重新连接' }}</button></div>
        <div v-else ref="workspace" class="search-workspace" :style="{ gridTemplateColumns: `${split}% 7px minmax(0, 1fr)` }">
          <div class="results-pane">
            <div class="pane-heading"><span>{{ query ? '搜索结果' : '全部已索引文件' }} <strong>{{ result.total_hits.toLocaleString() }}</strong></span><span>{{ result.elapsed_ms }} ms</span></div>
            <div class="result-list" aria-label="搜索结果" :aria-busy="searching">
              <div v-if="!result.hits.length" class="empty-state no-results"><Search :size="28" /><h3>没有找到匹配文件</h3><p>{{ stats?.indexing ? '文件正在索引中，稍后刷新即可查看。' : '试试更短的关键词，或调整文件类型筛选。' }}</p><div v-if="history.length" class="history"><span>最近搜索</span><button v-for="item in history.slice(0, 4)" :key="item" @click="query = item">{{ item }}</button></div></div>
              <button v-for="hit in result.hits" :key="hit.path" class="result-item" :class="{ selected: selected?.path === hit.path }" :aria-pressed="selected?.path === hit.path" @click="select(hit)" @dblclick="run(() => openPath(hit.path))" @contextmenu.prevent="showContext(hit)">
                <div class="file-icon" :data-ext="hit.ext"><component :is="iconFor(hit.ext)" :size="21" /></div><div class="result-copy"><div class="result-title"><HighlightedText :parts="snippetParts(hit.filename_hl)" /></div><div class="result-path" :title="hit.path">{{ hit.path }}</div><div class="result-snippet"><HighlightedText :parts="snippetParts(hit.snippets[0] ?? '')" /></div><div class="result-meta"><span>{{ hit.ext.toUpperCase() || '文件' }}</span><span>{{ bytes(hit.size) }}</span><span>{{ date(hit.mtime) }}</span><span v-if="hit.ocr_page">第 {{ hit.ocr_page }} 页</span></div></div>
              </button>
            </div>
            <div class="pagination"><span>{{ result.total_hits ? page * PAGE_SIZE + 1 : 0 }}–{{ Math.min((page + 1) * PAGE_SIZE, result.total_hits) }} / {{ result.total_hits }}</span><div><button class="icon-button" aria-label="上一页" :disabled="page === 0 || searching" @click="changePage(page - 1)"><ChevronLeft :size="17" /></button><span>{{ page + 1 }} / {{ pageCount }}</span><button class="icon-button" aria-label="下一页" :disabled="page + 1 >= pageCount || searching" @click="changePage(page + 1)"><ChevronRight :size="17" /></button></div></div>
          </div>
          <div class="splitter" role="separator" aria-label="调整预览宽度" aria-orientation="vertical" :aria-valuenow="split" :aria-valuemin="33" :aria-valuemax="65" tabindex="0" @pointerdown="resize" @pointermove="moveSplit" @keydown.left.prevent="split = Math.max(33, split - 2)" @keydown.right.prevent="split = Math.min(65, split + 2)"></div>
          <div class="preview-pane">
            <div class="pane-heading"><span>文件预览</span><span v-if="selected">{{ selected.ext.toUpperCase() }} 文档</span></div>
            <template v-if="selected"><div class="preview-header"><h2 :title="selected.filename">{{ selected.filename }}</h2><p :title="selected.path">{{ selected.path }}</p><div class="preview-actions"><button class="secondary small" @click="run(() => openPath(selected!.path))"><ArrowUpRight :size="14" />打开文件</button><button class="icon-button" title="打开所在文件夹" aria-label="打开所在文件夹" @click="run(() => openPath(selected!.path, true))"><FolderOpen :size="16" /></button><button class="icon-button" title="复制路径" aria-label="复制路径" @click="copyPath"><Copy :size="15" /></button></div></div><div v-if="previewLoading" class="empty-state"><LoaderCircle :size="24" class="spinning" /><p>正在提取文件内容…</p></div><div v-else-if="previewError" class="preview-message" role="alert">{{ previewError }}</div><template v-else><div v-if="preview?.needs_ocr" class="preview-message">此文件需要 OCR 识别，可在设置中开启。</div><div v-if="preview?.truncated" class="preview-message">仅显示部分内容，打开文件可查看全文。</div><div ref="previewElement" class="preview-text" tabindex="0"><HighlightedText :parts="previewText" /><p v-if="preview && !preview.text" class="muted">暂无可预览的文字。</p></div></template></template>
            <div v-else class="empty-state"><FileText :size="30" /><h3>在这里查看文件内容</h3><p>选择左侧的搜索结果即可预览。</p></div>
          </div>
        </div>
      </section>

      <section v-if="view === 'folders'" class="settings-page">
        <div class="page-heading"><div><h1>索引文件夹</h1><p>选择搜索范围，文件变化会自动更新到索引。</p></div><button class="secondary" :disabled="!connected || busy" @click="run(() => action(stats?.paused ? 'index.resume' : 'index.pause'))"><Play v-if="stats?.paused" :size="15" /><Pause v-else :size="15" />{{ stats?.paused ? '恢复索引' : '暂停索引' }}</button></div>
        <div class="stats-grid"><div><span>已索引文件</span><strong>{{ (stats?.total_docs ?? 0).toLocaleString() }}<FileText :size="20" /></strong></div><div><span>索引占用</span><strong>{{ bytes(stats?.index_size_bytes ?? 0) }}<HardDrive :size="20" /></strong></div><div><span>处理失败</span><strong>{{ stats?.failed_docs ?? 0 }}<File :size="20" /></strong></div></div>
        <div class="section-card"><div class="card-title"><h2>添加文件夹</h2><p>建议选择常用文档目录，避免索引整个磁盘。</p></div><form class="folder-form" @submit.prevent="addRoot"><input v-model="pathInput" aria-label="文件夹路径" placeholder="输入文件夹完整路径，例如 D:\Documents" /><button class="secondary" type="button" :disabled="busy" @click="browse"><FolderOpen :size="16" />浏览</button><button class="primary" :disabled="!connected || busy || !pathInput.trim()"><Plus :size="16" />添加</button></form></div>
        <div class="section-card"><div class="card-title row"><h2>已添加的文件夹 <span class="count">{{ roots.length }}</span></h2><button class="text-button" :disabled="!connected" @click="refreshStatus"><RefreshCw :size="14" />刷新状态</button></div><div v-if="!roots.length" class="folder-empty"><Folder :size="28" /><p>尚未添加文件夹，在上方选择一个目录开始。</p></div><div v-for="root in roots" :key="root.path" class="folder-row"><div class="folder-icon"><Folder :size="22" /></div><div class="folder-info"><strong :title="root.path">{{ root.path }}</strong><span>{{ root.total_docs.toLocaleString() }} 个文件</span></div><button class="secondary small" :disabled="busy || !connected" @click="run(() => action('index.rebuild', { root: root.path }, '已安排重建此文件夹的索引。'))"><RefreshCw :size="14" />重建索引</button><button class="icon-button danger" title="移除索引" aria-label="移除索引" :disabled="busy || !connected" @click="askRemove(root)"><Trash2 :size="16" /></button></div></div>
        <div class="index-status"><span class="status-dot" :class="{ offline: !connected, working: stats?.indexing }"></span><strong>{{ status }}</strong><span v-if="progress">{{ progress.done }} / {{ progress.total }} · {{ progress.failed }} 个失败</span><span v-if="progress" class="current-file" :title="progress.current_file">{{ progress.current_file }}</span></div>
        <div v-if="progress" class="progress-track"><span :style="{ width: `${progressPercent}%` }"></span></div>
      </section>

      <section v-if="view === 'settings'" class="settings-page">
        <div class="page-heading"><div><h1>设置</h1><p>调整搜索习惯，让工作空间更顺手。</p></div></div>
        <div class="section-card"><div class="card-title"><h2>外观</h2><p>主题与关闭窗口偏好由三个前端共用。</p></div><div class="theme-options"><button v-for="option in [{ value: 'light', label: '浅色' }, { value: 'dark', label: '深色' }]" :key="option.value" :class="{ chosen: theme === option.value }" :aria-pressed="theme === option.value" @click="setTheme(option.value)"><Moon v-if="option.value === 'dark'" :size="17" /><Sun v-else :size="17" />{{ option.label }}<Check v-if="theme === option.value" :size="15" /></button></div></div>
        <form v-if="settings" :inert="migrating" @submit.prevent="saveSettings">
          <div class="section-card"><div class="card-title"><h2>索引选项</h2><p>修改后会自动重新扫描受影响的文件。</p></div><label class="setting-row"><span><strong>最大文件大小</strong><small>超出限制的文件将跳过索引。</small></span><div class="number-field"><input v-model.number="settings.max_file_size_mb" aria-label="最大文件大小" type="number" min="1" max="2048" required />MB</div></label><label class="stacked-label"><strong>忽略的目录</strong><span>每行一个目录名，例如 node_modules。</span><textarea v-model="skipDirs" aria-label="忽略的目录" rows="4" spellcheck="false"></textarea></label><label class="stacked-label"><strong>自定义分词词典</strong><span>每行一个词，可用于人名、产品名和专业术语。</span><textarea v-model="settings.user_dictionary" aria-label="自定义分词词典" rows="3" spellcheck="false" placeholder="例如：冰槐搜索"></textarea></label></div>
          <div class="section-card"><div class="card-title"><h2>文字识别 OCR</h2><p>识别图片和扫描 PDF 中的文字，全部在本机完成。</p></div><label class="setting-row"><span><strong>开启文字识别</strong><small>普通文件索引完成后，后台逐个处理。</small></span><input v-model="settings.ocr_enabled" type="checkbox" class="switch" aria-label="开启文字识别" /></label><div class="ocr-options"><label><input v-model="settings.ocr_images" type="checkbox" :disabled="!settings.ocr_enabled" />图片文件</label><label><input v-model="settings.ocr_pdf" type="checkbox" :disabled="!settings.ocr_enabled" />扫描 PDF</label><label>PDF 页数上限<input v-model.number="settings.ocr_max_pages" aria-label="PDF 页数上限" type="number" min="1" max="500" required :disabled="!settings.ocr_enabled" /></label></div><div class="ocr-status"><span>待识别 {{ stats?.ocr_pending ?? 0 }} · 失败 {{ stats?.ocr_failed ?? 0 }}</span><button class="text-button" type="button" :disabled="busy || !connected" @click="run(() => action('ocr.retry_failed', {}, '已将失败文件加入重试队列。'))"><RefreshCw :size="13" />重试失败文件</button></div></div>
          <div class="save-row"><span>索引选项与其他界面共用。</span><button class="primary" :disabled="busy || !connected"><Check :size="16" />{{ busy ? '正在保存…' : '保存索引设置' }}</button></div>
        </form>
        <div class="section-card" :inert="migrating"><div class="card-title"><h2>窗口与托盘</h2></div><label class="setting-row"><span><strong>关闭主窗口时最小化到托盘</strong><small>在托盘菜单中选择“退出”可完全退出。</small></span><input v-model="closeToTray" type="checkbox" class="switch" aria-label="关闭主窗口时最小化到托盘" @change="saveDesktop" /></label></div>
        <div class="section-card"><div class="card-title"><h2>数据目录</h2><p class="dialog-path">{{ desktop?.data_directory }}</p></div><div :inert="migrating"><button class="secondary small" :disabled="!desktop" @click="run(() => openPath(desktop!.data_directory))">打开数据目录</button><div class="folder-form"><input v-model="targetData" aria-label="新的数据目录" placeholder="输入新的数据目录完整路径" /><button class="secondary" :disabled="busy" @click="browseData">浏览目录</button></div><label class="setting-row"><span>迁移现有索引和设置（目标必须为空）</span><input v-model="migrateData" type="checkbox" aria-label="迁移现有索引和设置" /></label><button class="primary" :disabled="busy || !connected || !targetData.trim()" @click="migrationDialog?.showModal()">更换数据目录</button></div><div v-if="migrating" role="status"><p>{{ migrationProgress }}</p><button class="secondary" @click="invoke('cancel_migration')">取消迁移</button></div></div>
        <div class="section-card"><div class="card-title"><h2>MCP 接入</h2><p>允许 AI 客户端搜索已索引文件。客户端可能将返回的正文发送给模型服务。迁移前请关闭其他前端和 MCP 客户端。</p></div><p>{{ desktop?.mcp_installed ? 'MCP 已安装' : 'MCP 程序未打包' }} · 引擎连接 {{ stats?.active_clients ?? 0 }} 个 · PID {{ stats?.engine_pid }}</p><p class="dialog-path">{{ desktop?.mcp_path }}</p><div class="preview-actions"><button class="secondary" :disabled="!desktop?.mcp_installed || busy" @click="copyMcp('claude')">复制 Claude Desktop 配置</button><button class="secondary" :disabled="!desktop?.mcp_installed || busy" @click="copyMcp('codex')">复制 Codex 配置</button></div></div>
        <div class="section-card about-card"><span class="brand-icon"><Search :size="20" /></span><div><strong>RustSearch</strong><p>本地全文搜索 · {{ stats?.version ?? version }}</p></div><ShieldCheck :size="21" /><p v-if="stats?.data_directory" class="data-path">数据目录：{{ stats.data_directory }}</p></div>
      </section>
      <footer><span><span class="status-dot" :class="{ offline: !connected, working: stats?.indexing }"></span>{{ status }}</span><span>{{ stats?.indexing ? '索引在后台进行，搜索结果可手动刷新' : '本地搜索，安心专注' }}</span></footer>
    </main>
    <dialog ref="historyDialog" class="modal" aria-label="搜索历史"><h2>搜索历史</h2><div class="history"><button v-for="item in history" :key="item" @click="query = item; historyDialog?.close()">{{ item }}</button><p v-if="!history.length">暂无搜索记录</p></div><div class="dialog-actions"><button class="secondary" @click="historyDialog?.close()">关闭</button></div></dialog>
    <dialog ref="contextDialog" class="modal" aria-label="文件操作"><h2>{{ contextHit?.filename }}</h2><div class="dialog-actions"><button class="secondary" @click="contextDialog?.close(); run(() => openPath(contextHit!.path))">打开文件</button><button class="secondary" @click="contextDialog?.close(); run(() => openPath(contextHit!.path, true))">打开所在文件夹</button><button class="secondary" @click="contextDialog?.close(); copyPath()">复制路径</button><button class="secondary" @click="contextDialog?.close()">关闭</button></div></dialog>
    <dialog ref="migrationDialog" class="modal" aria-label="确认更换数据目录"><h2>{{ migrateData ? '迁移并切换数据目录？' : '切换数据目录？' }}</h2><p class="dialog-path">{{ targetData }}</p><p>{{ migrateData ? '复制并校验现有数据，新目录验证成功后清理原目录中的索引和已迁移配置。' : '使用目标目录中的索引和设置，原目录的数据将保留。' }}</p><div class="dialog-actions"><button class="secondary" @click="migrationDialog?.close()">取消</button><button class="primary" @click="changeData">确认切换</button></div></dialog>
    <dialog ref="removeDialog" class="modal" aria-labelledby="remove-title"><h2 id="remove-title">移除这个文件夹的索引？</h2><p class="dialog-path">{{ removeTarget?.path }}</p><p>仅从搜索范围中移除，文件夹中的源文件会保留。</p><div class="dialog-actions"><button class="secondary" @click="removeDialog?.close()">取消</button><button class="primary destructive" @click="removeRoot">移除索引</button></div></dialog>
    <dialog ref="helpDialog" class="modal help-modal" aria-labelledby="help-title"><div class="row"><h2 id="help-title">搜索语法</h2><button class="icon-button" aria-label="关闭搜索语法" @click="helpDialog?.close()"><X :size="18" /></button></div><p>组合关键词与条件，更快缩小搜索范围。</p><dl><dt>合同 报价</dt><dd>匹配任一关键词</dd><dt>"采购合同"</dt><dd>精确短语</dd><dt>+合同 -过期</dt><dd>必含与排除词</dd><dt>合同 ext:pdf,docx</dt><dd>限定文件类型</dd><dt>size:&gt;1mb</dt><dd>筛选文件大小</dd><dt>date:&gt;=2026-01-01</dt><dd>筛选修改日期</dd><dt>path:C:\work\*</dt><dd>限定路径前缀</dd></dl><div class="dialog-actions"><button class="primary" @click="helpDialog?.close()">知道了</button></div></dialog>
  </div>
</template>
