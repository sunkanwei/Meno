/*
 * Focused static renderer derived from MarkText 0.19.1 / Muya 0.2.0.
 * It keeps the upstream parser behaviour needed by Quick Look without
 * bundling Muya's editor, UI, collaboration code, or dynamic language loader.
 */

import type { Lexer, MarkedExtension, Token, Tokens } from 'marked';
import { Marked } from 'marked';
import { markedHighlight } from 'marked-highlight';
import katex from 'katex';
import Prism from 'prismjs';

import 'prismjs/components/prism-bash';
import 'prismjs/components/prism-c';
import 'prismjs/components/prism-cpp';
import 'prismjs/components/prism-csharp';
import 'prismjs/components/prism-dart';
import 'prismjs/components/prism-diff';
import 'prismjs/components/prism-docker';
import 'prismjs/components/prism-go';
import 'prismjs/components/prism-graphql';
import 'prismjs/components/prism-java';
import 'prismjs/components/prism-json';
import 'prismjs/components/prism-kotlin';
import 'prismjs/components/prism-lua';
import 'prismjs/components/prism-markdown';
import 'prismjs/components/prism-objectivec';
import 'prismjs/components/prism-php';
import 'prismjs/components/prism-powershell';
import 'prismjs/components/prism-python';
import 'prismjs/components/prism-r';
import 'prismjs/components/prism-ruby';
import 'prismjs/components/prism-rust';
import 'prismjs/components/prism-scala';
import 'prismjs/components/prism-sql';
import 'prismjs/components/prism-swift';
import 'prismjs/components/prism-toml';
import 'prismjs/components/prism-typescript';
import 'prismjs/components/prism-verilog';
import 'prismjs/components/prism-vhdl';
import 'prismjs/components/prism-yaml';

const diagramLanguages = new Set(['mermaid', 'vega', 'vega-lite']);
const languageAliases: Record<string, string> = {
  cxx: 'cpp', 'c++': 'cpp', cs: 'csharp', dockerfile: 'docker', gql: 'graphql',
  js: 'javascript', kt: 'kotlin', md: 'markdown', objc: 'objectivec', ps1: 'powershell',
  py: 'python', rb: 'ruby', rs: 'rust', sh: 'bash', shell: 'bash', text: 'plain',
  ts: 'typescript', yml: 'yaml',
};

function highlight(code: string, language?: string): string {
  if (!language) return code;
  const normalized = languageAliases[language.toLowerCase()] ?? language.toLowerCase();
  if (diagramLanguages.has(normalized)) return code;
  const grammar = Prism.languages[normalized];
  return grammar ? Prism.highlight(code, grammar, normalized) : code;
}

interface MathToken {
  type: 'inlineMath' | 'multiplemath';
  raw: string;
  text: string;
  displayMode: boolean;
  mathStyle?: '' | 'gitlab';
}

const inlineMathStart = /(\s|^)\${1,2}(?!\$)/;
const inlineMathRule = /^(\${1,2})(?!\$)((?:\\.|[^\\\n])*?(?:\\.|[^\\\n$]))\1(?=[\s?!.,:，。！？；：]|$)/;
const blockMathRule = /^(\${1,2})\n((?:\\[\s\S]|[^\\])+?)\n\1(?:\n|$)/;

function mathExtension(): MarkedExtension {
  const render = (token: MathToken, newline: boolean) => katex.renderToString(token.text, {
    displayMode: token.displayMode,
    throwOnError: false,
  }) + (newline ? '\n' : '');

  return {
    extensions: [
      {
        name: 'inlineMath',
        level: 'inline',
        start(source: string) {
          const match = source.match(inlineMathStart);
          if (!match) return undefined;
          const index = (match.index ?? 0) + match[1].length;
          return inlineMathRule.test(source.substring(index)) ? index : undefined;
        },
        tokenizer(source: string) {
          const match = source.match(inlineMathRule);
          if (!match) return undefined;
          return {
            type: 'inlineMath', raw: match[0], text: match[2].trim(), displayMode: match[1].length === 2,
          };
        },
        renderer(token) { return render(token as MathToken, false); },
      },
      {
        name: 'multiplemath',
        level: 'block',
        start(source: string) { return source.indexOf('\n$'); },
        tokenizer(source: string) {
          const match = source.match(blockMathRule);
          if (!match) return undefined;
          return {
            type: 'multiplemath', raw: match[0], text: match[2].trim(), displayMode: match[1].length === 2,
          };
        },
        renderer(token) { return render(token as MathToken, true); },
      },
    ],
  };
}

const subStart = /(\s|^)~(?!~)/;
const subRule = /^(~)((?:[^~\s]|(?<=\\)\1|(?<=\\) )+?)(?<!\\)\1(?!\1)/;
const supStart = /(^|[^\s[])\^(?!\^)/;
const supRule = /^(\^)((?:[^^\s[\]]|(?<=\\)\1|(?<=\\) )+?)(?<!\\)\1(?!\1)/;

function superSubscriptExtension(): MarkedExtension {
  return {
    extensions: [
      scriptExtension('superscript', supStart, supRule, 'sup'),
      scriptExtension('subscript', subStart, subRule, 'sub'),
    ],
  };
}

function scriptExtension(
  name: 'superscript' | 'subscript',
  startRule: RegExp,
  tokenRule: RegExp,
  tag: 'sup' | 'sub',
) {
  return {
    name,
    level: 'inline' as const,
    start(source: string) {
      const match = source.match(startRule);
      if (!match) return undefined;
      const index = (match.index ?? 0) + match[1].length;
      return tokenRule.test(source.substring(index)) ? index : undefined;
    },
    tokenizer(source: string) {
      const match = source.match(tokenRule);
      if (!match) return undefined;
      return { type: name, raw: match[0], text: match[2].trim() };
    },
    renderer(token: Tokens.Generic) { return `<${tag}>${escapeHTML(token.text as string)}</${tag}>`; },
  };
}

interface FootnoteToken {
  type: 'footnote';
  raw: string;
  identifier: string;
  tokens: Tokens.Generic[];
}

interface FootnoteTokenizerContext { lexer: Lexer; }
interface FootnoteRendererContext { parser?: { parse(tokens: Tokens.Generic[]): string }; }

const footnoteBlock = /^\[\^([^^[\]\s]+)(?<!\\)\]:([\s\S]*?)(?=\n *\n {0,3}[^ ]|$)/;

function footnoteExtension(): MarkedExtension {
  return {
    extensions: [{
      name: 'footnote',
      level: 'block',
      start(source: string) {
        const match = /\n\[\^[^^[\]\s]+(?<!\\)\]:/.exec(source);
        return match ? match.index + 1 : undefined;
      },
      tokenizer(this: unknown, source: string) {
        const match = footnoteBlock.exec(source);
        if (!match) return undefined;
        const cleaned = match[2]
          .replace(/^[ \t]*/, '')
          .replace(/^\n+/, '')
          .replace(/^ {4}/, '')
          .replace(/\n {4}(?=\S)/g, '\n')
          .replace(/\n+$/, '');
        const { lexer } = this as FootnoteTokenizerContext;
        return {
          type: 'footnote',
          raw: match[0],
          identifier: match[1],
          tokens: cleaned ? lexer.blockTokens(cleaned, []) as Tokens.Generic[] : [],
        } as FootnoteToken;
      },
      renderer(this: unknown, token) {
        const footnote = token as FootnoteToken;
        const inner = (this as FootnoteRendererContext).parser?.parse(footnote.tokens) ?? '';
        return `<div class="footnote-block" data-identifier="${escapeAttribute(footnote.identifier)}">${inner}</div>\n`;
      },
    }],
  };
}

function escapeAttribute(value: string): string {
  return value.replace(/[&<>"]/g, (character) => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;',
  }[character] ?? character));
}

function escapeHTML(value: string): string {
  return value.replace(/[&<>]/g, (character) => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;',
  }[character] ?? character));
}

function getFrontMatter(source: string): { html: string; body: string } {
  const match = /^(?:---\n([\s\S]+?)---|\+\+\+\n([\s\S]+?)\+\+\+|;;;\n([\s\S]+?);;;|\{\n([\s\S]+?)\})(?:\n{2,}|\n{1,2}$)/.exec(source);
  if (!match) return { html: '', body: source };
  const style = match[0][0];
  const language = style === '-' ? 'yaml' : style === '+' ? 'toml' : 'json';
  const content = match[1] ?? match[2] ?? match[3] ?? match[4] ?? '';
  return {
    html: `<pre class="front-matter" data-style="${style}" data-lang="${language}">\n${escapeHTML(content)}</pre>\n`,
    body: source.substring(match[0].length),
  };
}

function walkToken(token: Token | Tokens.Generic): void {
  if (token.type !== 'code') return;
  const code = token as Tokens.Code & { codeBlockStyle?: string; mathStyle?: string; displayMode?: boolean };
  if (code.codeBlockStyle === 'indented') code.lang = '';
  if (code.lang !== 'math') return;
  (code as unknown as { type: string }).type = 'multiplemath';
  code.mathStyle = 'gitlab';
  code.displayMode = true;
  delete code.lang;
  delete code.codeBlockStyle;
}

export function renderMarkTextMarkdown(markdown: string): string {
  if (!markdown) return '';
  const parser = new Marked(markedHighlight({ highlight }));
  parser.use({ walkTokens: walkToken });
  parser.use(mathExtension());
  parser.use(superSubscriptExtension());
  parser.use(footnoteExtension());

  const frontMatter = getFrontMatter(markdown);
  const parsed = parser.parse(frontMatter.body);
  const html = frontMatter.html + (typeof parsed === 'string' ? parsed : '');
  return transformFootnotes(html);
}

const footnoteReference = /\[\^([^\[\]\s]+)\]/g;

function transformFootnotes(html: string): string {
  const template = document.createElement('template');
  template.innerHTML = html;

  const definitions = new Map<string, string>();
  template.content.querySelectorAll<HTMLElement>('.footnote-block[data-identifier]').forEach((element) => {
    const identifier = element.dataset.identifier;
    if (identifier && !definitions.has(identifier)) definitions.set(identifier, element.innerHTML);
    element.remove();
  });
  if (definitions.size === 0) return html;

  const references = new Map<string, { number: number; anchors: string[] }>();
  const textNodes: Text[] = [];
  const walker = document.createTreeWalker(template.content, NodeFilter.SHOW_TEXT);
  while (walker.nextNode()) {
    const node = walker.currentNode as Text;
    if (node.parentElement?.closest('code, pre, script, style')) continue;
    footnoteReference.lastIndex = 0;
    if (footnoteReference.test(node.data)) textNodes.push(node);
  }

  textNodes.forEach((node) => {
    const fragment = document.createDocumentFragment();
    let offset = 0;
    footnoteReference.lastIndex = 0;
    for (const match of node.data.matchAll(footnoteReference)) {
      const identifier = match[1];
      if (!definitions.has(identifier) || match.index === undefined) continue;

      fragment.append(node.data.slice(offset, match.index));
      let reference = references.get(identifier);
      if (!reference) {
        reference = { number: references.size + 1, anchors: [] };
        references.set(identifier, reference);
      }

      const anchorID = reference.anchors.length === 0
        ? `fnref-${reference.number}`
        : `fnref-${reference.number}-${reference.anchors.length + 1}`;
      reference.anchors.push(anchorID);

      const superscript = document.createElement('sup');
      superscript.className = 'footnote-ref';
      const anchor = document.createElement('a');
      anchor.href = `#fn-${reference.number}`;
      anchor.id = anchorID;
      anchor.textContent = String(reference.number);
      superscript.append(anchor);
      fragment.append(superscript);
      offset = match.index + match[0].length;
    }
    fragment.append(node.data.slice(offset));
    node.replaceWith(fragment);
  });
  if (references.size > 0) {
    const section = document.createElement('section');
    section.className = 'footnotes';
    const list = document.createElement('ol');
    section.append(list);

    references.forEach((reference, identifier) => {
      const item = document.createElement('li');
      item.id = `fn-${reference.number}`;
      item.innerHTML = definitions.get(identifier) ?? '';
      const backlinkTarget = item.querySelector('p:last-child') ?? item;
      reference.anchors.forEach((anchorID) => {
        backlinkTarget.append(' ');
        const backlink = document.createElement('a');
        backlink.href = `#${anchorID}`;
        backlink.className = 'footnote-backref';
        backlink.textContent = '↩';
        backlinkTarget.append(backlink);
      });
      list.append(item);
    });
    template.content.append(section);
  }

  const container = document.createElement('div');
  container.append(template.content);
  return container.innerHTML;
}
