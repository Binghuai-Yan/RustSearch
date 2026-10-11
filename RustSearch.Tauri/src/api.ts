import { invoke, isTauri } from '@tauri-apps/api/core';
import contract from '../../frontends.json';

export interface Stats {
  total_docs: number; failed_docs: number; roots: number; indexing: boolean;
  paused: boolean; index_size_bytes: number; version: string;
  ocr_pending: number; ocr_failed: number; data_directory?: string; active_clients: number; engine_pid?: number;
}
export interface Root { path: string; total_docs: number; added_at: number }
export interface Hit {
  path: string; filename: string; filename_hl: string; ext: string; size: number;
  mtime: number; score: number; snippets: string[]; ocr_page?: number;
}
export interface SearchResult { total_hits: number; elapsed_ms: number; hits: Hit[]; page: number; page_size: number }
export interface Preview { text: string; path: string; truncated: boolean; needs_ocr: boolean }
export interface Config {
  max_file_size_mb: number; skip_dirs: string[]; user_dictionary: string;
  paused: boolean; ocr_enabled: boolean; ocr_images: boolean; ocr_pdf: boolean; ocr_max_pages: number;
}
export interface Progress { root: string; total: number; done: number; failed: number; current_file: string }
export interface BackendEvent { event: string; data: Progress & { message?: string } }
export const PAGE_SIZE = contract.page_size;
export const FILE_FILTERS = contract.filters.map((filter) => ({ label: filter.label, value: filter.extensions.join(',') }));
export interface DesktopSettings {
  theme: string; close_to_tray: boolean; data_directory: string;
  mcp_installed: boolean; mcp_path: string; claude: string; codex: string;
}

export function call<T>(method: string, params: Record<string, unknown> = {}): Promise<T> {
  if (!isTauri()) return Promise.reject(new Error('请通过 npm run desktop 启动桌面应用，以连接本地搜索引擎。'));
  return invoke<T>('backend_call', { method, params });
}
export function openPath(path: string, reveal = false) {
  return invoke<void>('open_local_path', { path, reveal });
}
export function errorText(error: unknown): string {
  const message = error instanceof Error ? error.message : String(error);
  if (message.startsWith('INDEX_BUSY:')) return '索引正在处理文件，请稍后重试。';
  if (message.startsWith('QUERY_SYNTAX_ERROR:')) return '搜索语法有误，请检查引号、筛选条件和关键词。';
  if (message.startsWith('ROOT_NOT_FOUND:')) return '文件夹不存在或无法访问，请检查路径。';
  return message;
}
export function bytes(value: number) {
  if (value >= 1073741824) return `${(value / 1073741824).toFixed(1)} GB`;
  if (value >= 1048576) return `${(value / 1048576).toFixed(1)} MB`;
  if (value >= 1024) return `${(value / 1024).toFixed(1)} KB`;
  return `${value} B`;
}
export function date(value: number) {
  return new Date(value * 1000).toLocaleDateString('zh-CN', { year: 'numeric', month: '2-digit', day: '2-digit' });
}
