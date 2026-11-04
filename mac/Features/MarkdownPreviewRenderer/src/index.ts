import 'katex/dist/katex.min.css';
import './theme.css';
import { renderDiagrams } from './diagrams';
import { renderMarkTextMarkdown } from './marktext-renderer';
import { sanitizeRenderedHTML } from './render-security';

function postMessage(name: string, value: unknown): void {
  try {
    window.webkit?.messageHandlers?.[name]?.postMessage(value);
  } catch {
    // The renderer also runs in a normal browser during local development.
  }
}

function log(message: string): void {
  postMessage('logger', message);
}

export function prepareImages(container: HTMLElement): void {
  container.querySelectorAll<HTMLImageElement>('img[src]').forEach((image) => {
    const source = image.getAttribute('src');
    if (!source) return;

    if (!/^(?:data:|blob:)/i.test(source)) {
      const notice = document.createElement('span');
      notice.className = 'image-unavailable';
      notice.textContent = image.alt ? `图片：${image.alt}` : '图片未显示';
      image.replaceWith(notice);
      return;
    }

    image.loading = 'lazy';
    image.decoding = 'async';
  });
}

function slugify(value: string): string {
  return value
    .trim()
    .toLocaleLowerCase()
    .replace(/[^\p{Letter}\p{Number}\s_-]/gu, '')
    .replace(/[\s_]+/g, '-')
    .replace(/-+/g, '-')
    .replace(/^-|-$/g, '') || 'section';
}

function assignHeadingAnchors(container: HTMLElement): void {
  const headings = container.querySelectorAll<HTMLElement>('h1, h2, h3, h4, h5, h6');
  const headingElements = new Set<Element>(headings);
  const usedIDs = new Set<string>();
  document.querySelectorAll('[id]').forEach((element) => {
    if (!headingElements.has(element)) usedIDs.add(element.id);
  });
  const nextSuffixes = new Map<string, number>();
  headings.forEach((heading) => {
    const base = slugify(heading.textContent ?? '');
    let suffix = nextSuffixes.get(base) ?? 0;
    let id = suffix === 0 ? base : `${base}-${suffix}`;
    while (usedIDs.has(id)) {
      suffix += 1;
      id = `${base}-${suffix}`;
    }
    nextSuffixes.set(base, suffix + 1);
    usedIDs.add(id);
    heading.id = id;
  });
}

function prepareLinks(container: HTMLElement): void {
  container.querySelectorAll<HTMLAnchorElement>('a[href]').forEach((anchor) => {
    anchor.removeAttribute('target');
    anchor.removeAttribute('download');
    anchor.rel = 'noopener noreferrer';
  });
}

export function normalizeNumberedTaskItems(container: HTMLElement): void {
  container.querySelectorAll<HTMLLIElement>('li').forEach((item) => {
    const checkbox = item.firstElementChild;
    if (!(checkbox instanceof HTMLInputElement) || checkbox.type !== 'checkbox') return;
    const orderedList = checkbox.nextElementSibling;
    if (!(orderedList instanceof HTMLOListElement) || orderedList.children.length !== 1) return;
    const nestedItem = orderedList.firstElementChild;
    if (!(nestedItem instanceof HTMLLIElement)) return;

    let sibling = checkbox.nextSibling;
    while (sibling && sibling !== orderedList) {
      const next = sibling.nextSibling;
      if (sibling.nodeType === Node.TEXT_NODE && !(sibling.textContent ?? '').trim()) sibling.remove();
      sibling = next;
    }

    checkbox.after(document.createTextNode(` ${orderedList.start}. `));
    while (nestedItem.firstChild) orderedList.before(nestedItem.firstChild);
    orderedList.remove();
  });
}

function scrollToAnchor(href: string): void {
  let id = href.slice(1);
  try { id = decodeURIComponent(id); } catch { /* Keep malformed identifiers literal. */ }
  document.getElementById(id)?.scrollIntoView({ behavior: 'smooth', block: 'start' });
}

document.addEventListener('click', (event) => {
  const anchor = (event.target as Element | null)?.closest<HTMLAnchorElement>('a[href]');
  if (!anchor) return;
  event.preventDefault();
  event.stopPropagation();
  const href = anchor.getAttribute('href') ?? '';
  if (href.startsWith('#')) scrollToAnchor(href);
  else postMessage('linkClicked', href);
}, { capture: true });

document.addEventListener('wheel', (event) => {
  if (!event.metaKey && !event.ctrlKey) return;
  event.preventDefault();
  postMessage('wheelZoom', -event.deltaY * 0.01);
}, { passive: false });

window.addEventListener('error', (event) => {
  log(`renderer error: ${event.message}`);
});

window.addEventListener('unhandledrejection', () => {
  log('renderer error: unhandled promise rejection');
});

window.renderMarkdown = async (markdown: string) => {
  const output = document.getElementById('markdown-preview');
  const loading = document.getElementById('loading-status');
  if (!(output instanceof HTMLElement)) throw new Error('Preview root is unavailable');

  loading?.classList.add('hidden');
  output.classList.remove('ready');
  output.replaceChildren();

  try {
    const html = renderMarkTextMarkdown(markdown);
    output.innerHTML = sanitizeRenderedHTML(html);
    normalizeNumberedTaskItems(output);
    assignHeadingAnchors(output);
    prepareLinks(output);
    prepareImages(output);
    const dark = window.matchMedia('(prefers-color-scheme: dark)').matches;
    await renderDiagrams(output, dark);
    output.classList.add('ready');
  } catch (error) {
    output.replaceChildren();
    const message = document.createElement('div');
    message.className = 'render-error';
    message.textContent = 'Markdown 内容无法预览。';
    output.append(message);
    log(`renderer error: ${error instanceof Error ? error.message : String(error)}`);
    throw error;
  }
};

log('rendererReady');
