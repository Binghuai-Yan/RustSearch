export interface TextPart { text: string; marked: boolean }

// Decode only after splitting the backend's literal <b> tags. Never render
// document content as HTML, including escaped tags inside search results.
function decode(text: string) {
  return text.replace(/&(#x[\da-f]+|#\d+|amp|lt|gt|quot|apos|#x27);/gi, (entity, code: string) => {
    const named: Record<string, string> = { amp: '&', lt: '<', gt: '>', quot: '"', apos: "'" };
    if (named[code.toLowerCase()]) return named[code.toLowerCase()];
    const value = code.toLowerCase().startsWith('#x') ? parseInt(code.slice(2), 16) : parseInt(code.slice(1), 10);
    return Number.isInteger(value) && value > 0 && value <= 0x10ffff ? String.fromCodePoint(value) : entity;
  });
}
export function snippetParts(html: string): TextPart[] {
  let marked = false;
  return html.split(/(<\/?b>)/i).flatMap((text) => {
    if (text.toLowerCase() === '<b>') { marked = true; return []; }
    if (text.toLowerCase() === '</b>') { marked = false; return []; }
    return text ? [{ text: decode(text), marked }] : [];
  });
}
export function previewParts(text: string, terms: string[]): TextPart[] {
  const clean = [...new Set(terms.filter(Boolean))].sort((a, b) => b.length - a.length);
  if (!clean.length) return [{ text, marked: false }];
  const pattern = new RegExp(`(${clean.map((term) => term.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')).join('|')})`, 'gi');
  return text.split(pattern).map((part, index) => ({ text: part, marked: index % 2 === 1 }));
}
