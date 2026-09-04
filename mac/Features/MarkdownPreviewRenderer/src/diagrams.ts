import {
  containsExternalResource,
  RenderComplexityBudget,
  sanitizeDiagramMarkup,
} from './render-security';

let mermaidTheme: 'default' | 'dark' | null = null;
let diagramSequence = 0;

function replaceWithError(element: Element, message: string): void {
  const error = document.createElement('div');
  error.className = 'diagram-error';
  error.textContent = message;
  element.replaceWith(error);
}

function sourceBlocks(container: HTMLElement, language: string): HTMLElement[] {
  return Array.from(container.querySelectorAll<HTMLElement>(`pre > code.language-${language}`));
}

export async function renderDiagrams(container: HTMLElement, dark: boolean): Promise<void> {
  const budget = new RenderComplexityBudget();
  await renderMermaid(container, dark, budget);
  await renderVega(container, dark, budget);
}

async function renderMermaid(
  container: HTMLElement,
  dark: boolean,
  budget: RenderComplexityBudget,
): Promise<void> {
  const blocks = sourceBlocks(container, 'mermaid');
  if (blocks.length === 0) return;

  const accepted = blocks.flatMap((block) => {
    const source = block.textContent ?? '';
    const wrapper = block.parentElement;
    if (!wrapper || !budget.acceptSource(source)) {
      if (wrapper) replaceWithError(wrapper, '流程图内容过大，无法预览。');
      return [];
    }
    return [{ source, wrapper }];
  });
  if (accepted.length === 0) return;

  const mermaid = (await import('mermaid')).default;
  const theme = dark ? 'dark' : 'default';
  if (mermaidTheme !== theme) {
    mermaid.initialize({
      startOnLoad: false,
      theme,
      htmlLabels: false,
      securityLevel: 'strict',
      suppressErrorRendering: true,
    });
    mermaidTheme = theme;
  }

  for (const { source, wrapper } of accepted) {
    try {
      diagramSequence += 1;
      const result = await mermaid.render(`meno-mermaid-${diagramSequence}`, source);
      const safeSVG = sanitizeDiagramMarkup(result.svg);
      if (!safeSVG || !budget.acceptOutput(safeSVG)) {
        replaceWithError(wrapper, '流程图生成结果过大，无法预览。');
        continue;
      }
      const rendered = document.createElement('div');
      rendered.className = 'diagram mermaid-diagram';
      rendered.innerHTML = safeSVG;
      wrapper.replaceWith(rendered);
    } catch {
      replaceWithError(wrapper, '流程图语法有误，无法显示。');
    }
  }
}

async function renderVega(
  container: HTMLElement,
  dark: boolean,
  budget: RenderComplexityBudget,
): Promise<void> {
  const blocks = [
    ...sourceBlocks(container, 'vega').map((block) => ({ block, isVegaLite: false })),
    ...sourceBlocks(container, 'vega-lite').map((block) => ({ block, isVegaLite: true })),
  ];
  if (blocks.length === 0) return;

  const embed = (await import('vega-embed')).default;
  for (const { block, isVegaLite } of blocks) {
    const source = block.textContent ?? '';
    const wrapper = block.parentElement;
    if (!wrapper || !budget.acceptSource(source)) {
      if (wrapper) replaceWithError(wrapper, '数据图表内容过大，无法预览。');
      continue;
    }

    try {
      const specification = prepareVegaSpecification(
        JSON.parse(source) as Record<string, unknown>,
        isVegaLite,
      );
      if (containsExternalResource(specification)) {
        replaceWithError(wrapper, '数据图表引用了外部资源，已阻止加载。');
        continue;
      }
      const detached = document.createElement('div');
      const view = await embed(detached, specification, {
        actions: false,
        renderer: 'svg',
        theme: dark ? 'dark' : undefined,
      });
      const svg = detached.querySelector('svg')?.outerHTML ?? '';
      view.finalize();
      const safeSVG = sanitizeDiagramMarkup(svg);
      if (!safeSVG || !budget.acceptOutput(safeSVG)) {
        replaceWithError(wrapper, '数据图表生成结果过大，无法预览。');
        continue;
      }
      const rendered = document.createElement('div');
      rendered.className = 'diagram vega-diagram';
      rendered.innerHTML = safeSVG;
      wrapper.replaceWith(rendered);
    } catch {
      replaceWithError(wrapper, '数据图表语法有误，无法显示。');
    }
  }
}

export function prepareVegaSpecification(
  specification: Record<string, unknown>,
  isVegaLite: boolean,
): Record<string, unknown> {
  if (!isVegaLite) return specification;
  return {
    ...specification,
    width: specification.width ?? 420,
    height: specification.height ?? 260,
  };
}
