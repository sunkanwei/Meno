import { describe, expect, test } from 'vitest';
import { renderMarkTextMarkdown } from '../marktext-renderer';
import { sanitizeRenderedHTML } from '../render-security';

describe('MarkText static rendering', () => {
  test('renders GFM structures and task lists', () => {
    const html = sanitizeRenderedHTML(renderMarkTextMarkdown(
      '# 标题\n\n- [x] 完成\n- [ ] 待办\n\n| A | B |\n| - | - |\n| 1 | 2 |',
    ));
    expect(html).toContain('<h1>标题</h1>');
    expect(html).toContain('type="checkbox"');
    expect(html).toContain('<table>');
  });

  test('renders math, footnotes, and fenced diagram placeholders', () => {
    const html = sanitizeRenderedHTML(renderMarkTextMarkdown(
      '公式 $x^2$。脚注[^a]\n\n[^a]: 内容\n\n```mermaid\ngraph TD; A-->B\n```',
    ));
    expect(html).toContain('class="katex"');
    expect(html).toContain('class="footnotes"');
    expect(html).toContain('language-mermaid');
  });

  test('keeps footnote-like text inert and gives repeated references unique anchors', () => {
    const html = sanitizeRenderedHTML(renderMarkTextMarkdown(
      '[链接](https://example.com "标题[^a]")、`[^a]`、引用[^a]和再次引用[^a]\n\n[^a]: 内容',
    ));
    expect(html).toContain('title="标题[^a]"');
    expect(html).toContain('<code>[^a]</code>');
    expect(html).toContain('id="fnref-1"');
    expect(html).toContain('id="fnref-1-2"');
    expect(html.match(/class="footnote-backref"/g)).toHaveLength(2);
  });

  test('renders super- and subscripts without consuming footnote markers', () => {
    const html = sanitizeRenderedHTML(renderMarkTextMarkdown(
      '^top^ H~2~O 脚注[^a]\n\n[^a]: 内容',
    ));
    expect(html).toContain('<sup>top</sup>');
    expect(html).toContain('<sub>2</sub>');
    expect(html).toContain('id="fnref-1"');
  });

  test('leaves malicious input inert after final sanitization', () => {
    const html = sanitizeRenderedHTML(renderMarkTextMarkdown(
      '<script>alert(1)</script><img src="x" onerror="alert(2)">',
    ));
    expect(html).not.toContain('<script');
    expect(html).not.toContain('onerror');
  });

  test('escapes active markup inside front matter before sanitizing the document', () => {
    const rawHTML = renderMarkTextMarkdown(
      '---\ntitle: </pre><script>alert(1)</script>\n---\n\nX^2<3^\n\n<img src=x onerror=alert(2)>',
    );
    expect(rawHTML).toContain('&lt;/pre&gt;&lt;script&gt;');
    const html = sanitizeRenderedHTML(rawHTML);
    expect(html).not.toContain('<script>');
    expect(html).not.toContain('onerror');
  });
});
