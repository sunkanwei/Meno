import DOMPurify from 'dompurify';

export const renderLimits = {
    maximumFrontMatterBytes: 64 * 1024,
    maximumFrontMatterDepth: 32,
    maximumFrontMatterNodes: 2000,
    maximumDiagramCount: 32,
    maximumDiagramSourceBytes: 64 * 1024,
    maximumTotalDiagramSourceBytes: 256 * 1024,
    maximumDiagramOutputBytes: 2 * 1024 * 1024,
    maximumTotalDiagramOutputBytes: 8 * 1024 * 1024,
} as const;

const forbiddenHTMLTags = [
    'script', 'style', 'iframe', 'object', 'embed', 'form', 'input', 'button',
    'meta', 'base', 'link', 'audio', 'video',
];
const allowedURI = /^(?:(?:https?|mailto|data|blob|local-md):|[^a-z]|[a-z+.-]+(?:[^a-z+.-:]|$))/i;

export function utf8ByteLength(value: string): number {
    let bytes = 0;
    for (let index = 0; index < value.length; index += 1) {
        const codePoint = value.codePointAt(index) ?? 0;
        if (codePoint <= 0x7f) bytes += 1;
        else if (codePoint <= 0x7ff) bytes += 2;
        else if (codePoint <= 0xffff) bytes += 3;
        else {
            bytes += 4;
            index += 1;
        }
    }
    return bytes;
}

export function sanitizeRawHTML(value: string): string {
    return DOMPurify.sanitize(value, {
        USE_PROFILES: { html: true },
        FORBID_TAGS: forbiddenHTMLTags,
        FORBID_ATTR: ['style', 'srcset'],
        ALLOW_DATA_ATTR: false,
        ALLOW_UNKNOWN_PROTOCOLS: false,
        ALLOWED_URI_REGEXP: allowedURI,
    });
}

export function sanitizeRenderedHTML(value: string): string {
    return DOMPurify.sanitize(value, {
        USE_PROFILES: { html: true, mathMl: true },
        FORBID_TAGS: forbiddenHTMLTags,
        FORBID_ATTR: ['srcset'],
        ALLOW_DATA_ATTR: true,
        ALLOW_UNKNOWN_PROTOCOLS: false,
        ALLOWED_URI_REGEXP: allowedURI,
    });
}

export function sanitizeDiagramMarkup(value: string): string {
    const fragment = DOMPurify.sanitize(value, {
        USE_PROFILES: { html: true, svg: true, svgFilters: true, mathMl: true },
        FORBID_TAGS: [
            'script', 'iframe', 'object', 'embed', 'foreignObject', 'form', 'input',
        ],
        ADD_TAGS: ['use'],
        ADD_ATTR: ['href', 'xlink:href'],
        ALLOW_DATA_ATTR: true,
        ALLOW_UNKNOWN_PROTOCOLS: false,
        RETURN_DOM_FRAGMENT: true,
    }) as DocumentFragment;

    fragment.querySelectorAll('*').forEach((element) => {
        if (element.tagName.toLowerCase() === 'style') {
            const css = element.textContent || '';
            if (/@import\b/i.test(css) || /url\((?!\s*["']?#)/i.test(css)) {
                element.remove();
                return;
            }
        }
        for (const name of ['href', 'xlink:href', 'src', 'data']) {
            const value = element.getAttribute(name);
            if (value != null && !value.startsWith('#')) {
                element.removeAttribute(name);
            }
        }
        const style = element.getAttribute('style');
        if (style && /url\((?!\s*["']?#)/i.test(style)) {
            element.removeAttribute('style');
        }
        for (const attribute of Array.from(element.attributes)) {
            if (/^on/i.test(attribute.name)) {
                element.removeAttribute(attribute.name);
            }
        }
    });
    const container = document.createElement('div');
    container.append(fragment);
    return container.innerHTML;
}

export class RenderComplexityBudget {
    private diagramCount = 0;
    private totalSourceBytes = 0;
    private totalOutputBytes = 0;

    acceptSource(source: string): string | null {
        const bytes = utf8ByteLength(source);
        if (this.diagramCount >= renderLimits.maximumDiagramCount) {
            return 'Too many diagram blocks';
        }
        if (bytes > renderLimits.maximumDiagramSourceBytes) {
            return 'Diagram source is too large';
        }
        if (this.totalSourceBytes > renderLimits.maximumTotalDiagramSourceBytes - bytes) {
            return 'Total diagram source is too large';
        }
        this.diagramCount += 1;
        this.totalSourceBytes += bytes;
        return null;
    }

    acceptOutput(output: string): string | null {
        const bytes = utf8ByteLength(output);
        if (bytes > renderLimits.maximumDiagramOutputBytes) {
            return 'Diagram output is too large';
        }
        if (this.totalOutputBytes > renderLimits.maximumTotalDiagramOutputBytes - bytes) {
            return 'Total diagram output is too large';
        }
        this.totalOutputBytes += bytes;
        return null;
    }
}

interface FrontMatterRenderState {
    nodes: number;
    ancestors: WeakSet<object>;
}

export function renderFrontMatterValue(value: unknown): string {
    const state: FrontMatterRenderState = {
        nodes: 0,
        ancestors: new WeakSet<object>(),
    };
    return renderValue(value, 0, state);
}

function renderValue(value: unknown, depth: number, state: FrontMatterRenderState): string {
    state.nodes += 1;
    if (depth > renderLimits.maximumFrontMatterDepth
        || state.nodes > renderLimits.maximumFrontMatterNodes) {
        return '<span class="yaml-limit">front matter 过于复杂</span>';
    }
    if (value === null || value === undefined) return '';
    if (typeof value !== 'object') return escapeHTML(String(value));

    const object = value as object;
    if (state.ancestors.has(object)) {
        return '<span class="yaml-limit">循环引用</span>';
    }
    state.ancestors.add(object);
    let result: string;
    if (Array.isArray(value)) {
        result = '<ul>' + value.map((item) => `<li>${renderValue(item, depth + 1, state)}</li>`).join('') + '</ul>';
    } else {
        const rows = Object.entries(value as Record<string, unknown>).map(([key, item]) => (
            `<tr><th>${escapeHTML(key)}</th><td>${renderValue(item, depth + 1, state)}</td></tr>`
        )).join('');
        result = `<table class="yaml-frontmatter"><tbody>${rows}</tbody></table>`;
    }
    state.ancestors.delete(object);
    return result;
}

function escapeHTML(value: string): string {
    return value
        .replace(/&/g, '&amp;')
        .replace(/</g, '&lt;')
        .replace(/>/g, '&gt;')
        .replace(/"/g, '&quot;')
        .replace(/'/g, '&#039;');
}
