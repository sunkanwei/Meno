import {
    RenderComplexityBudget,
    renderFrontMatterValue,
    renderLimits,
    sanitizeDiagramMarkup,
    sanitizeRawHTML,
    sanitizeRenderedHTML,
} from '../render-security';

describe('renderer security boundaries', () => {
    test('removes active content and event handlers from raw HTML', () => {
        const sanitized = sanitizeRawHTML(
            '<script>alert(1)</script><img src="x" onerror="alert(2)" style="position:fixed">ok'
        );

        expect(sanitized).not.toContain('<script');
        expect(sanitized).not.toContain('onerror');
        expect(sanitized).not.toContain('style=');
        expect(sanitized).toContain('ok');
        expect(sanitizeRawHTML('<a href="javascript:alert(1)">bad</a>'))
            .not.toContain('javascript:');
        expect(sanitizeRawHTML('<img src="local-md:///tmp/image.png">'))
            .toContain('local-md:///tmp/image.png');

        const finalHTML = sanitizeRenderedHTML(
            '<math><mi>x</mi></math><a href="javascript:alert(1)" onclick="alert(2)">bad</a>'
        );
        expect(finalHTML).toContain('<math>');
        expect(finalHTML).not.toContain('javascript:');
        expect(finalHTML).not.toContain('onclick');
    });

    test('removes external resources from generated SVG', () => {
        const sanitized = sanitizeDiagramMarkup(
            '<svg><image href="https://example.invalid/pixel.png" onload="alert(1)" />' +
            '<style>@import url(https://example.invalid/style.css)</style>' +
            '<style>.node { fill: red }</style><use href="#local-symbol" /></svg>'
        );

        expect(sanitized).not.toContain('https://');
        expect(sanitized).not.toContain('onload');
        expect(sanitized).not.toContain('@import');
        expect(sanitized).toContain('.node { fill: red }');
        expect(sanitized).toContain('#local-symbol');
    });

    test('front matter renderer terminates on cycles', () => {
        const value: Record<string, unknown> = {};
        value.self = value;

        expect(renderFrontMatterValue(value)).toContain('循环引用');
    });

    test('front matter renderer caps depth and node count', () => {
        const deep: Record<string, unknown> = {};
        let cursor = deep;
        for (let index = 0; index < renderLimits.maximumFrontMatterDepth + 2; index += 1) {
            const newNode: Record<string, unknown> = {};
            cursor[String(index)] = newNode;
            cursor = newNode;
        }
        expect(renderFrontMatterValue(deep)).toContain('front matter 过于复杂');

        const wide = Array.from(
            { length: renderLimits.maximumFrontMatterNodes + 1 },
            (_, index) => index
        );
        expect(renderFrontMatterValue(wide)).toContain('front matter 过于复杂');
    });

    test('diagram budget rejects per-item and aggregate overflow', () => {
        const oversized = new RenderComplexityBudget();
        expect(oversized.acceptSource('x'.repeat(renderLimits.maximumDiagramSourceBytes + 1)))
            .toBe('Diagram source is too large');

        const aggregate = new RenderComplexityBudget();
        const chunk = 'x'.repeat(renderLimits.maximumDiagramSourceBytes);
        for (let index = 0; index < 4; index += 1) {
            expect(aggregate.acceptSource(chunk)).toBeNull();
        }
        expect(aggregate.acceptSource('x')).toBe('Total diagram source is too large');

        const output = new RenderComplexityBudget();
        expect(output.acceptOutput('x'.repeat(renderLimits.maximumDiagramOutputBytes + 1)))
            .toBe('Diagram output is too large');
    });
});
