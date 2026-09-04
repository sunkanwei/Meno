import DOMPurify from 'dompurify';

export const renderLimits = {
  maximumDiagramCount: 32,
  maximumDiagramSourceBytes: 64 * 1024,
  maximumTotalDiagramSourceBytes: 256 * 1024,
  maximumDiagramOutputBytes: 2 * 1024 * 1024,
  maximumTotalDiagramOutputBytes: 8 * 1024 * 1024,
} as const;

const forbiddenHTMLTags = [
  'script', 'style', 'iframe', 'object', 'embed', 'form', 'button',
  'meta', 'base', 'link', 'audio', 'video',
];

const allowedURI = /^(?:(?:https?|mailto|data|blob):|[^a-z]|[a-z+.-]+(?:[^a-z+.-:]|$))/i;

export function utf8ByteLength(value: string): number {
  return new TextEncoder().encode(value).byteLength;
}

export function sanitizeRenderedHTML(value: string): string {
  const fragment = DOMPurify.sanitize(value, {
    USE_PROFILES: { html: true, svg: true, svgFilters: true, mathMl: true },
    FORBID_TAGS: forbiddenHTMLTags,
    FORBID_ATTR: ['contenteditable', 'srcset'],
    ALLOW_DATA_ATTR: true,
    ALLOW_UNKNOWN_PROTOCOLS: false,
    ALLOWED_URI_REGEXP: allowedURI,
    RETURN_DOM_FRAGMENT: true,
  }) as DocumentFragment;

  fragment.querySelectorAll('input').forEach((input) => {
    if (input.getAttribute('type')?.toLowerCase() !== 'checkbox') {
      input.remove();
      return;
    }
    const checked = input.hasAttribute('checked');
    for (const attribute of Array.from(input.attributes)) input.removeAttribute(attribute.name);
    input.setAttribute('type', 'checkbox');
    input.setAttribute('disabled', '');
    if (checked) input.setAttribute('checked', '');
  });

  fragment.querySelectorAll<HTMLElement>('[style]').forEach((element) => {
    const style = element.getAttribute('style') ?? '';
    if (/@import\b|expression\s*\(|url\s*\(|behavior\s*:|position\s*:\s*(?:fixed|sticky)/i.test(style)) {
      element.removeAttribute('style');
    }
  });

  const container = document.createElement('div');
  container.append(fragment);
  return container.innerHTML;
}

export function sanitizeDiagramMarkup(value: string): string {
  const fragment = DOMPurify.sanitize(value, {
    USE_PROFILES: { html: true, svg: true, svgFilters: true, mathMl: true },
    FORBID_TAGS: ['script', 'iframe', 'object', 'embed', 'foreignObject', 'form', 'input'],
    ADD_TAGS: ['use'],
    ADD_ATTR: ['href', 'xlink:href'],
    ALLOW_DATA_ATTR: true,
    ALLOW_UNKNOWN_PROTOCOLS: false,
    RETURN_DOM_FRAGMENT: true,
  }) as DocumentFragment;

  fragment.querySelectorAll('*').forEach((element) => {
    if (element.tagName.toLowerCase() === 'style') {
      const css = element.textContent ?? '';
      if (/@import\b/i.test(css) || /url\((?!\s*["']?#)/i.test(css)) {
        element.remove();
        return;
      }
    }
    for (const name of ['href', 'xlink:href', 'src', 'data']) {
      const attribute = element.getAttribute(name);
      if (attribute !== null && !attribute.startsWith('#')) element.removeAttribute(name);
    }
    const style = element.getAttribute('style');
    if (style && /url\((?!\s*["']?#)|@import\b|expression\s*\(/i.test(style)) {
      element.removeAttribute('style');
    }
    for (const attribute of Array.from(element.attributes)) {
      if (/^on/i.test(attribute.name)) element.removeAttribute(attribute.name);
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

  acceptSource(source: string): boolean {
    const bytes = utf8ByteLength(source);
    if (this.diagramCount >= renderLimits.maximumDiagramCount) return false;
    if (bytes > renderLimits.maximumDiagramSourceBytes) return false;
    if (this.totalSourceBytes > renderLimits.maximumTotalDiagramSourceBytes - bytes) return false;
    this.diagramCount += 1;
    this.totalSourceBytes += bytes;
    return true;
  }

  acceptOutput(output: string): boolean {
    const bytes = utf8ByteLength(output);
    if (bytes > renderLimits.maximumDiagramOutputBytes) return false;
    if (this.totalOutputBytes > renderLimits.maximumTotalDiagramOutputBytes - bytes) return false;
    this.totalOutputBytes += bytes;
    return true;
  }
}

export function containsExternalResource(value: unknown): boolean {
  if (Array.isArray(value)) return value.some(containsExternalResource);
  if (!value || typeof value !== 'object') return false;

  return Object.entries(value as Record<string, unknown>).some(([key, item]) => {
    if (key.toLowerCase() === 'url' && typeof item === 'string') return true;
    return containsExternalResource(item);
  });
}
