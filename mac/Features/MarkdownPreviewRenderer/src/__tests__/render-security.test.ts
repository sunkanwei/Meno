import { describe, expect, test } from 'vitest';
import { prepareVegaSpecification } from '../diagrams';
import { normalizeNumberedTaskItems, prepareImages } from '../index';
import { renderMarkTextMarkdown } from '../marktext-renderer';
import {
  containsExternalResource,
  RenderComplexityBudget,
  renderLimits,
  sanitizeDiagramMarkup,
  sanitizeRenderedHTML,
} from '../render-security';

describe('Markdown preview security boundaries', () => {
  test('keeps inline images and replaces unavailable files with a quiet notice', () => {
    const container = document.createElement('div');
    container.innerHTML = '<img alt="本地图片" src="Markdown%E9%A2%84%E8%A7%88.png">'
      + '<img alt="内嵌图片" src="data:image/png;base64,AAAA">';
    prepareImages(container);
    expect(container.querySelector('.image-unavailable')?.textContent).toBe('图片：本地图片');
    expect(container.querySelectorAll('img')).toHaveLength(1);
    expect(container.querySelector('img')?.alt).toBe('内嵌图片');
  });

  test('keeps numbered task text on the same compact line', () => {
    const container = document.createElement('div');
    container.innerHTML = sanitizeRenderedHTML(renderMarkTextMarkdown(
      '- [x] 13. 修正透明命中区域',
    ));
    normalizeNumberedTaskItems(container);
    expect(container.querySelector('ol')).toBeNull();
    expect(container.querySelector('li')?.textContent).toContain('13. 修正透明命中区域');
  });

  test('removes active content but preserves disabled task checkboxes', () => {
    const html = sanitizeRenderedHTML(
      '<script>alert(1)</script><a href="javascript:alert(2)" onclick="alert(3)">bad</a>'
      + '<input type="text" value="secret"><input type="checkbox" checked onclick="alert(4)">',
    );
    expect(html).not.toContain('<script');
    expect(html).not.toContain('javascript:');
    expect(html).not.toContain('onclick');
    expect(html).not.toContain('type="text"');
    expect(html).toContain('type="checkbox"');
    expect(html).toContain('disabled');
    expect(html).toContain('checked');
  });

  test('removes external resources and handlers from diagram SVG', () => {
    const html = sanitizeDiagramMarkup(
      '<svg onload="alert(1)"><image href="https://example.invalid/a.png" />'
      + '<style>@import url(https://example.invalid/a.css)</style>'
      + '<style>.node { fill: red }</style><use href="#node" /></svg>',
    );
    expect(html).not.toContain('https://');
    expect(html).not.toContain('onload');
    expect(html).not.toContain('@import');
    expect(html).toContain('.node { fill: red }');
    expect(html).toContain('#node');
  });

  test('enforces diagram count and byte limits', () => {
    const budget = new RenderComplexityBudget();
    expect(budget.acceptSource('x'.repeat(renderLimits.maximumDiagramSourceBytes + 1))).toBe(false);

    const countBudget = new RenderComplexityBudget();
    for (let index = 0; index < renderLimits.maximumDiagramCount; index += 1) {
      expect(countBudget.acceptSource('x')).toBe(true);
    }
    expect(countBudget.acceptSource('x')).toBe(false);
  });

  test('rejects external data URLs in chart specifications', () => {
    expect(containsExternalResource({ data: { url: 'https://example.invalid/data.json' } })).toBe(true);
    expect(containsExternalResource({ data: { values: [{ x: 1, y: 2 }] } })).toBe(false);
  });

  test('gives Vega-Lite charts readable defaults without overriding explicit sizes', () => {
    expect(prepareVegaSpecification({ mark: 'bar' }, true)).toMatchObject({
      width: 420,
      height: 260,
    });
    expect(prepareVegaSpecification({ width: 180, height: 120 }, true)).toMatchObject({
      width: 180,
      height: 120,
    });
    expect(prepareVegaSpecification({ mark: 'bar' }, false)).toEqual({ mark: 'bar' });
  });
});
