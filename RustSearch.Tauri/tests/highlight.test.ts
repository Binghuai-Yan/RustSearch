import { describe, expect, it } from 'vitest';
import { previewParts, snippetParts } from '../src/highlight';

describe('untrusted document text', () => {
  it('keeps escaped HTML as literal text and only highlights backend markers', () => {
    expect(snippetParts('&lt;script&gt;alert(1)&lt;/script&gt; <b>合同</b> &amp; &#x1f600;')).toEqual([
      { text: '<script>alert(1)</script> ', marked: false },
      { text: '合同', marked: true }, { text: ' & 😀', marked: false },
    ]);
    expect(snippetParts('&lt;b&gt;原文&lt;/b&gt;')[0]).toEqual({ text: '<b>原文</b>', marked: false });
  });
  it('treats regular expression characters in matched terms literally', () => {
    const parts = previewParts('C++ 与 file.ts，还有 FILE.TS', ['C++', 'file.ts']);
    expect(parts.filter((p) => p.marked).map((p) => p.text)).toEqual(['C++', 'file.ts', 'FILE.TS']);
    expect(parts.map((p) => p.text).join('')).toBe('C++ 与 file.ts，还有 FILE.TS');
  });
  it('preserves unicode and does not decode entities twice', () => {
    expect(snippetParts('&amp;lt; &#99999999;')).toEqual([{ text: '&lt; &#99999999;', marked: false }]);
    expect(previewParts('中文内容', []).map((p) => p.text).join('')).toBe('中文内容');
  });
});
