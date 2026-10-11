import { computed, nextTick, onBeforeUnmount, onMounted, ref, watch } from 'vue';
import { listen, type UnlistenFn } from '@tauri-apps/api/event';
import { isTauri } from '@tauri-apps/api/core';
import { PAGE_SIZE, call, errorText, type BackendEvent, type Config, type Hit, type Preview, type Progress, type Root, type SearchResult, type Stats } from './api';
import { previewParts, snippetParts } from './highlight';

export function useSearch() {
  const connected = ref(false), connecting = ref(false), error = ref(''), notice = ref('');
  const stats = ref<Stats>(), roots = ref<Root[]>([]), config = ref<Config>(), history = ref<string[]>([]);
  const progress = ref<Progress>(), updated = ref(false);
  const migrating = ref(false);
  const query = ref(''), extension = ref(''), sort = ref('relevance'), page = ref(0);
  const composing = ref(false), searching = ref(false), searched = ref(false);
  const result = ref<SearchResult>({ hits: [], total_hits: 0, elapsed_ms: 0, page: 0, page_size: PAGE_SIZE });
  const selected = ref<Hit>(), preview = ref<Preview>(), previewLoading = ref(false), previewError = ref('');
  const previewElement = ref<HTMLElement>();
  let queryVersion = 0, previewVersion = 0, disposed = false;
  let debounce: ReturnType<typeof setTimeout> | undefined;
  let statusTimer: ReturnType<typeof setInterval> | undefined;
  let statusLoading = false;
  let reconnectAttempts = 0;
  let reconnectTimer: ReturnType<typeof setTimeout> | undefined;
  const unlisteners: UnlistenFn[] = [];
  const pageCount = computed(() => Math.max(1, Math.ceil(result.value.total_hits / PAGE_SIZE)));
  const previewText = computed(() => {
    const hit = selected.value;
    const terms = hit ? [hit.filename_hl, ...hit.snippets].flatMap((snippet) => snippetParts(snippet).filter((p) => p.marked).map((p) => p.text)) : [];
    return previewParts(preview.value?.text ?? '', terms);
  });

  async function select(hit?: Hit) {
    const version = ++previewVersion;
    selected.value = hit;
    preview.value = undefined;
    previewError.value = '';
    previewLoading.value = !!hit;
    if (!hit) return;
    try {
      const response = await call<Preview>('doc.preview', { path: hit.path });
      if (version !== previewVersion || disposed) return;
      // Bound DOM size for very large documents while leaving the source untouched.
      preview.value = { ...response, text: response.text.slice(0, 250000), truncated: response.truncated || response.text.length > 250000 };
      await nextTick();
      const first = previewElement.value?.querySelector('mark');
      if (first) first.scrollIntoView({ block: 'center' });
      else if (previewElement.value) previewElement.value.scrollTop = 0;
    } catch (err) {
      if (version === previewVersion) previewError.value = errorText(err);
    } finally {
      if (version === previewVersion) previewLoading.value = false;
    }
  }

  async function search() {
    if (debounce) clearTimeout(debounce);
    const version = ++queryVersion;
    if (!connected.value || composing.value || migrating.value) return;
    searching.value = true;
    error.value = '';
    try {
      const response = await call<SearchResult>('search.query', {
        query: query.value, ext: extension.value ? extension.value.split(',') : [],
        sort: sort.value, page: page.value, page_size: PAGE_SIZE,
      });
      if (version !== queryVersion || disposed) return;
      const lastPage = Math.max(0, Math.ceil(response.total_hits / PAGE_SIZE) - 1);
      if (page.value > lastPage) { page.value = lastPage; await search(); return; }
      result.value = response;
      searched.value = true;
      updated.value = false;
      const keep = response.hits.find((h) => h.path === selected.value?.path);
      void select(keep ?? response.hits[0]);
      void call<{ queries: string[] }>('search.history').then((r) => { if (!disposed) history.value = r.queries; }).catch(() => {});
    } catch (err) {
      if (version === queryVersion) error.value = errorText(err);
    } finally {
      if (version === queryVersion) searching.value = false;
    }
  }

  function scheduleSearch() {
    ++queryVersion; // Invalidate an in-flight response immediately, before debounce.
    searching.value = false;
    if (debounce) clearTimeout(debounce);
    if (!composing.value) debounce = setTimeout(() => { void search(); }, 300);
  }
  watch([query, extension, sort], () => { page.value = 0; scheduleSearch(); });
  watch(composing, scheduleSearch);
  function changePage(next: number) { page.value = next; void search(); }

  async function refreshStatus() {
    if (statusLoading || !connected.value || migrating.value) return;
    statusLoading = true;
    try {
      const [currentStats, currentRoots] = await Promise.all([
        call<Stats>('app.stats'), call<{ roots: Root[] }>('index.list_roots'),
      ]);
      if (disposed) return;
      stats.value = currentStats;
      roots.value = currentRoots.roots;
      if (!currentStats.indexing) progress.value = undefined;
    } catch (err) { error.value = errorText(err); }
    finally { statusLoading = false; }
  }

  function reconnectLater() {
    clearTimeout(reconnectTimer);
    if (disposed || migrating.value || reconnectAttempts >= 3) return;
    reconnectAttempts++;
    reconnectTimer = setTimeout(() => { void connect(true); }, 2000);
  }
  async function connect(automatic: unknown = false) {
    if (connecting.value || migrating.value) return;
    clearTimeout(reconnectTimer);
    if (automatic !== true) reconnectAttempts = 0;
    connecting.value = true;
    error.value = '';
    try {
      const [currentStats, currentRoots, currentConfig, currentHistory] = await Promise.all([
        call<Stats>('app.stats'), call<{ roots: Root[] }>('index.list_roots'),
        call<Config>('config.get'), call<{ queries: string[] }>('search.history'),
      ]);
      if (disposed) return;
      stats.value = currentStats; roots.value = currentRoots.roots;
      config.value = currentConfig; history.value = currentHistory.queries;
      connected.value = true;
      reconnectAttempts = 0;
      await search();
    } catch (err) { error.value = errorText(err); connected.value = false; reconnectLater(); }
    finally { connecting.value = false; }
  }

  async function action(method: string, params: Record<string, unknown> = {}, message = '') {
    error.value = ''; notice.value = '';
    try {
      const response = await call<unknown>(method, params);
      if (message) notice.value = message;
      await refreshStatus();
      return response;
    } catch (err) { error.value = errorText(err); throw err; }
  }

  onMounted(async () => {
    if (isTauri()) {
      try {
        const listeners = await Promise.all([
          listen<BackendEvent>('backend-event', ({ payload }) => {
            if (payload.event === 'index.progress') progress.value = payload.data;
            if (['index.finished', 'watcher.change', 'ocr.progress', 'ocr.finished'].includes(payload.event)) {
              updated.value = true;
              void refreshStatus();
            }
          }),
          listen<string>('backend-disconnected', ({ payload }) => {
            connected.value = false;
            if (!migrating.value) { error.value = payload; reconnectLater(); }
            ++queryVersion; searching.value = false;
          }),
        ]);
        if (disposed) { listeners.forEach((stop) => stop()); return; }
        unlisteners.push(...listeners);
      } catch (err) { error.value = errorText(err); return; }
    }
    await connect();
    if (!disposed) statusTimer = setInterval(() => { void refreshStatus(); }, 5000);
  });
  onBeforeUnmount(() => {
    disposed = true;
    ++queryVersion; ++previewVersion;
    clearTimeout(debounce); clearInterval(statusTimer);
    clearTimeout(reconnectTimer);
    unlisteners.forEach((stop) => stop());
  });
  return { connected, connecting, error, notice, stats, roots, config, history, progress, updated, migrating,
    query, extension, sort, page, composing, searching, searched, result, selected, preview,
    previewLoading, previewError, previewElement, pageCount, previewText, select, search,
    changePage, refreshStatus, connect, action };
}
