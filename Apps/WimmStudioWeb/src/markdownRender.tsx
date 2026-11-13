import React from 'react';
import type { CommentThread } from './types';

export interface AsidePiece {
  text: string;
  isAside: boolean;
}

/**
 * Matches Wimm's `PersonalDocumentRendering.splitAsides`:
 * Secretary reservations are written as `^[…]` (Pandoc inline notes), with nested brackets allowed.
 */
export function splitAsides(text: String | string): AsidePiece[] {
  const str = String(text);
  const pieces: AsidePiece[] = [];
  let plain = '';
  let i = 0;

  while (i < str.length) {
    if (str[i] === '^' && str[i + 1] === '[') {
      const closeIdx = findMatchingBracket(str, i + 1);
      if (closeIdx !== -1) {
        if (plain.length > 0) {
          pieces.push({ text: plain, isAside: false });
          plain = '';
        }
        const inner = str.slice(i + 2, closeIdx).trim();
        if (inner.length > 0) {
          pieces.push({ text: inner, isAside: true });
        }
        i = closeIdx + 1;
        continue;
      }
    }
    plain += str[i];
    i++;
  }
  if (plain.length > 0) {
    pieces.push({ text: plain, isAside: false });
  }
  return pieces;
}

function findMatchingBracket(text: string, openPos: number): number {
  let depth = 0;
  for (let i = openPos; i < text.length; i++) {
    if (text[i] === '[') depth++;
    else if (text[i] === ']') {
      depth--;
      if (depth === 0) return i;
    }
  }
  return -1;
}

/**
 * Converts block/inline Markdown into the visible plain text (without `^[…]` asides,
 * `[S…]`/`[W…]`/`[U…]` source chips, or Markdown syntax characters), so multi-sentence
 * or whole-paragraph selections match accurately.
 */
export function toVisiblePlainText(markdown: string): string {
  const nonAside = splitAsides(markdown)
    .filter((p) => !p.isAside)
    .map((p) => p.text)
    .join('');

  return nonAside
    .replace(/\[[A-Z]+\d+\]/g, '')
    .replace(/\[([^\]]+)\]\([^)]+\)/g, '$1')
    .replace(/\*\*([^*]+)\*\*/g, '$1')
    .replace(/\*([^*\n]+)\*/g, '$1')
    .replace(/`([^`\n]+)`/g, '$1')
    .replace(/\s+/g, ' ')
    .trim();
}

interface InlineProps {
  text: string;
  showAsides: boolean;
  onOpenSource: (sourceIdOrHref: string) => void;
  onNavigateAnchor?: (anchor: string) => void;
  threads?: CommentThread[];
  activeSelectionQuote?: string | null;
  onSelectThread?: (threadId: string) => void;
}

type ParsedToken =
  | { kind: 'text'; text: string; visibleStart: number; visibleEnd: number }
  | { kind: 'bold'; inner: string; visibleStart: number; visibleEnd: number }
  | { kind: 'italic'; inner: string; visibleStart: number; visibleEnd: number }
  | { kind: 'code'; inner: string; visibleStart: number; visibleEnd: number }
  | { kind: 'link'; label: string; href: string; visibleStart: number; visibleEnd: number }
  | { kind: 'chip'; sourceId: string; visibleOffset: number };

function tokenizeWithVisibleOffsets(raw: string): {
  tokens: ParsedToken[];
  visibleText: string;
} {
  const tokenRegex =
    /(\[[A-Z]+\d+\])|(\*\*[^*]+\*\*)|(\*[^*\n]+\*)|(`[^`\n]+`)|(\[[^\]]+\]\([^)]+\))/g;

  const tokens: ParsedToken[] = [];
  let visibleText = '';
  let lastIndex = 0;
  let match: RegExpExecArray | null;

  const pushPlain = (str: string) => {
    if (!str) return;
    const start = visibleText.length;
    visibleText += str;
    tokens.push({ kind: 'text', text: str, visibleStart: start, visibleEnd: visibleText.length });
  };

  while ((match = tokenRegex.exec(raw)) !== null) {
    if (match.index > lastIndex) {
      pushPlain(raw.slice(lastIndex, match.index));
    }
    const full = match[0];
    if (match[1]) {
      tokens.push({
        kind: 'chip',
        sourceId: full.slice(1, -1),
        visibleOffset: visibleText.length,
      });
    } else if (match[2]) {
      const inner = full.slice(2, -2).replace(/\[[A-Z]+\d+\]/g, '');
      const start = visibleText.length;
      visibleText += inner;
      tokens.push({
        kind: 'bold',
        inner: full.slice(2, -2),
        visibleStart: start,
        visibleEnd: visibleText.length,
      });
    } else if (match[3]) {
      const inner = full.slice(1, -1);
      const start = visibleText.length;
      visibleText += inner;
      tokens.push({
        kind: 'italic',
        inner,
        visibleStart: start,
        visibleEnd: visibleText.length,
      });
    } else if (match[4]) {
      const inner = full.slice(1, -1);
      const start = visibleText.length;
      visibleText += inner;
      tokens.push({
        kind: 'code',
        inner,
        visibleStart: start,
        visibleEnd: visibleText.length,
      });
    } else if (match[5]) {
      const closeBracket = full.indexOf('](');
      const label = full.slice(1, closeBracket);
      const href = full.slice(closeBracket + 2, -1);
      if (/^[A-Z]+\d+$/.test(label)) {
        tokens.push({
          kind: 'chip',
          sourceId: label,
          visibleOffset: visibleText.length,
        });
      } else {
        const start = visibleText.length;
        visibleText += label;
        tokens.push({
          kind: 'link',
          label,
          href,
          visibleStart: start,
          visibleEnd: visibleText.length,
        });
      }
    }
    lastIndex = tokenRegex.lastIndex;
  }

  if (lastIndex < raw.length) {
    pushPlain(raw.slice(lastIndex));
  }

  return { tokens, visibleText };
}

interface HighlightSpan {
  start: number;
  end: number;
  thread?: CommentThread;
  isPreview?: boolean;
}

/**
 * Finds the `[start, end]` character range of `quote` inside `visibleText`,
 * tolerating whitespace/chip differences so multi-sentence and full-paragraph
 * quotes match across `**bold**` and `[S…]` chips.
 */
function findQuoteSpanInVisible(visibleText: string, rawQuote: string): { start: number; end: number } | null {
  const cleanedQuote = toVisiblePlainText(rawQuote);
  if (cleanedQuote.length < 2) return null;

  // 1. Direct substring match
  const exactIdx = visibleText.indexOf(cleanedQuote);
  if (exactIdx !== -1) {
    return { start: exactIdx, end: exactIdx + cleanedQuote.length };
  }

  // 2. Normalized whitespace/punctuation match with offset map back to visibleText
  const normChars: string[] = [];
  const normOffsets: number[] = [];
  for (let i = 0; i < visibleText.length; i++) {
    const ch = visibleText[i];
    if (/\s/.test(ch)) continue;
    normChars.push(ch.toLowerCase());
    normOffsets.push(i);
  }
  const normVisible = normChars.join('');
  const normQuote = cleanedQuote.replace(/\s+/g, '').toLowerCase();
  if (normQuote.length < 2) return null;

  const normIdx = normVisible.indexOf(normQuote);
  if (normIdx !== -1) {
    const start = normOffsets[normIdx];
    const end = normOffsets[normIdx + normQuote.length - 1] + 1;
    return { start, end };
  }

  return null;
}

function renderNonAsideRun(
  raw: string,
  onOpenSource: (sourceIdOrHref: string) => void,
  onNavigateAnchor?: (anchor: string) => void,
  threads: CommentThread[] = [],
  activeSelectionQuote?: string | null,
  onSelectThread?: (threadId: string) => void,
  keyPrefix = 'r'
): React.ReactNode[] {
  const { tokens, visibleText } = tokenizeWithVisibleOffsets(raw);

  // Collect highlight spans from threads + active selection preview
  const spans: HighlightSpan[] = [];
  if (activeSelectionQuote) {
    const found = findQuoteSpanInVisible(visibleText, activeSelectionQuote);
    if (found) {
      spans.push({ ...found, isPreview: true });
    }
  }
  for (const th of threads) {
    if (!th.root.quote) continue;
    const found = findQuoteSpanInVisible(visibleText, th.root.quote);
    if (found) {
      spans.push({ ...found, thread: th });
    }
  }

  const wrapIfHighlighted = (
    node: React.ReactNode,
    tokStart: number,
    tokEnd: number,
    key: string
  ): React.ReactNode => {
    const matchingSpan = spans.find((s) => tokStart < s.end && tokEnd > s.start);
    if (!matchingSpan) return node;
    const isEndToken = tokEnd >= matchingSpan.end && tokStart < matchingSpan.end;
    const th = matchingSpan.thread;

    return (
      <mark
        key={key}
        onClick={(e) => {
          if (th) {
            e.stopPropagation();
            onSelectThread?.(th.id);
          }
        }}
        className={
          matchingSpan.isPreview
            ? 'rounded bg-sky-500/25 px-0.5 text-sky-100 ring-1 ring-sky-400/40'
            : 'cursor-pointer rounded bg-amber-500/20 px-0.5 text-amber-100 underline decoration-amber-400/60 decoration-wavy underline-offset-4 transition hover:bg-amber-500/35'
        }
      >
        {node}
        {isEndToken && th?.root.reaction && (
          <span className="ml-1 text-xs select-none" data-chip="true">
            {th.root.reaction}
          </span>
        )}
      </mark>
    );
  };

  const out: React.ReactNode[] = [];

  tokens.forEach((tok, idx) => {
    const k = `${keyPrefix}-${idx}`;
    if (tok.kind === 'chip') {
      out.push(
        <button
          key={k}
          type="button"
          data-chip="true"
          onClick={(e) => {
            e.stopPropagation();
            onOpenSource(tok.sourceId);
          }}
          className="mx-0.5 inline-flex items-center rounded bg-sky-500/15 px-1.5 py-0.5 font-mono text-[11px] font-medium text-sky-300 ring-1 ring-sky-500/30 transition hover:bg-sky-500/30 hover:text-sky-100 select-none"
        >
          {tok.sourceId}
        </button>
      );
      return;
    }

    if (tok.kind === 'bold') {
      const el = (
        <strong key={k} className="font-semibold text-zinc-50">
          {tok.inner}
        </strong>
      );
      out.push(wrapIfHighlighted(el, tok.visibleStart, tok.visibleEnd, `${k}-m`));
      return;
    }

    if (tok.kind === 'italic') {
      const el = (
        <em key={k} className="italic text-zinc-200">
          {tok.inner}
        </em>
      );
      out.push(wrapIfHighlighted(el, tok.visibleStart, tok.visibleEnd, `${k}-m`));
      return;
    }

    if (tok.kind === 'code') {
      const el = (
        <code
          key={k}
          className="rounded bg-zinc-800/90 px-1.5 py-0.5 font-mono text-[0.9em] text-amber-300"
        >
          {tok.inner}
        </code>
      );
      out.push(wrapIfHighlighted(el, tok.visibleStart, tok.visibleEnd, `${k}-m`));
      return;
    }

    if (tok.kind === 'link') {
      const el = (
        <a
          key={k}
          href={tok.href}
          onClick={(e) => {
            e.preventDefault();
            e.stopPropagation();
            if (tok.href.startsWith('#')) {
              onNavigateAnchor?.(tok.href.slice(1));
            } else if (/^https?:\/\//i.test(tok.href)) {
              window.location.href = tok.href;
            } else {
              onOpenSource(tok.href);
            }
          }}
          className="text-sky-400 underline decoration-sky-400/40 underline-offset-2 hover:text-sky-300"
        >
          {tok.label}
        </a>
      );
      out.push(wrapIfHighlighted(el, tok.visibleStart, tok.visibleEnd, `${k}-m`));
      return;
    }

    // tok.kind === 'text': split at any span boundaries that fall inside this plain text token
    const overlapping = spans.filter(
      (s) => tok.visibleStart < s.end && tok.visibleEnd > s.start
    );
    if (overlapping.length === 0) {
      out.push(tok.text);
      return;
    }

    // Slice plain text around the first matching span
    const span = overlapping[0];
    const relStart = Math.max(0, span.start - tok.visibleStart);
    const relEnd = Math.min(tok.text.length, span.end - tok.visibleStart);
    const before = tok.text.slice(0, relStart);
    const middle = tok.text.slice(relStart, relEnd);
    const after = tok.text.slice(relEnd);

    if (before) out.push(before);
    if (middle) {
      out.push(
        wrapIfHighlighted(
          middle,
          tok.visibleStart + relStart,
          tok.visibleStart + relEnd,
          `${k}-mid`
        )
      );
    }
    if (after) out.push(after);
  });

  return out;
}

export const InlineMarkdown: React.FC<InlineProps> = ({
  text,
  showAsides,
  onOpenSource,
  onNavigateAnchor,
  threads,
  activeSelectionQuote,
  onSelectThread,
}) => {
  const pieces = splitAsides(text);
  return (
    <>
      {pieces.map((piece, i) => {
        if (piece.isAside) {
          if (!showAsides) return null;
          return (
            <span
              key={i}
              data-aside="true"
              className="mx-1 inline rounded-md bg-zinc-800/80 px-2 py-0.5 text-[0.86em] text-zinc-400 ring-1 ring-zinc-700/60 select-none"
            >
              <span className="mr-1 font-mono text-[10px] text-zinc-500">примечание:</span>
              {renderNonAsideRun(
                piece.text,
                onOpenSource,
                onNavigateAnchor,
                [],
                null,
                onSelectThread,
                `aside-${i}`
              )}
            </span>
          );
        }
        return (
          <React.Fragment key={i}>
            {renderNonAsideRun(
              piece.text,
              onOpenSource,
              onNavigateAnchor,
              threads,
              activeSelectionQuote,
              onSelectThread,
              `plain-${i}`
            )}
          </React.Fragment>
        );
      })}
    </>
  );
};

interface BlockBodyProps {
  markdown: string;
  showAsides: boolean;
  onOpenSource: (sourceIdOrHref: string) => void;
  onNavigateAnchor?: (anchor: string) => void;
  threads?: CommentThread[];
  activeSelectionQuote?: string | null;
  onSelectThread?: (threadId: string) => void;
}

export const BlockBodyRenderer: React.FC<BlockBodyProps> = ({
  markdown,
  showAsides,
  onOpenSource,
  onNavigateAnchor,
  threads,
  activeSelectionQuote,
  onSelectThread,
}) => {
  const trimmed = markdown.trim();

  // Fenced code block
  if (trimmed.startsWith('```') || trimmed.startsWith('~~~')) {
    const lines = trimmed.split('\n');
    const code = lines
      .slice(1, lines[lines.length - 1].startsWith(trimmed.slice(0, 3)) ? -1 : undefined)
      .join('\n');
    return (
      <pre
        tabIndex={0}
        className="overflow-x-auto rounded-lg border border-zinc-800 bg-zinc-900/90 p-3.5 font-mono text-xs leading-relaxed text-zinc-200"
      >
        <code>{code}</code>
      </pre>
    );
  }

  // Horizontal rule
  if (/^(-{3,}|\*{3,}|_{3,})$/.test(trimmed)) {
    return <hr className="my-4 border-zinc-800" />;
  }

  const lines = trimmed.split('\n');

  // Markdown table
  if (
    lines.length >= 2 &&
    lines[0].includes('|') &&
    /^\s*\|?[\s:|-]+\|[\s:|-]*$/.test(lines[1])
  ) {
    const parseRow = (line: string) =>
      line
        .trim()
        .replace(/^\|/, '')
        .replace(/\|$/, '')
        .split('|')
        .map((c) => c.trim());
    const headers = parseRow(lines[0]);
    const rows = lines.slice(2).map(parseRow);
    return (
      <div className="my-2 overflow-x-auto rounded-lg border border-zinc-800">
        <table className="w-full border-collapse text-left text-sm">
          <thead className="bg-zinc-900/80 text-xs uppercase text-zinc-400">
            <tr>
              {headers.map((h, i) => (
                <th key={i} className="border-b border-zinc-800 px-3 py-2 font-semibold">
                  <InlineMarkdown
                    text={h}
                    showAsides={showAsides}
                    onOpenSource={onOpenSource}
                    onNavigateAnchor={onNavigateAnchor}
                    threads={threads}
                    activeSelectionQuote={activeSelectionQuote}
                    onSelectThread={onSelectThread}
                  />
                </th>
              ))}
            </tr>
          </thead>
          <tbody className="divide-y divide-zinc-800/70">
            {rows.map((r, ri) => (
              <tr key={ri} className="hover:bg-zinc-900/40">
                {r.map((cell, ci) => (
                  <td key={ci} className="px-3 py-2 align-top text-zinc-200">
                    <InlineMarkdown
                      text={cell}
                      showAsides={showAsides}
                      onOpenSource={onOpenSource}
                      onNavigateAnchor={onNavigateAnchor}
                      threads={threads}
                      activeSelectionQuote={activeSelectionQuote}
                      onSelectThread={onSelectThread}
                    />
                  </td>
                ))}
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    );
  }

  // Blockquote
  if (lines.every((l) => l.trim().startsWith('>'))) {
    const content = lines.map((l) => l.replace(/^\s*>\s?/, '')).join('\n');
    return (
      <blockquote className="border-l-2 border-zinc-700 pl-4 italic text-zinc-300">
        <InlineMarkdown
          text={content}
          showAsides={showAsides}
          onOpenSource={onOpenSource}
          onNavigateAnchor={onNavigateAnchor}
          threads={threads}
          activeSelectionQuote={activeSelectionQuote}
          onSelectThread={onSelectThread}
        />
      </blockquote>
    );
  }

  // List block (if lines start with bullet or number)
  const isListLine = (l: string) => /^\s*(?:[-+*]|\d+[.)])\s+/.test(l);
  if (lines.some(isListLine)) {
    return (
      <ul className="space-y-1.5">
        {lines.map((line, i) => {
          const indentMatch = /^(\s*)/.exec(line);
          const indentSpaces = indentMatch ? indentMatch[1].length : 0;
          const bulletMatch = /^\s*([-+*]|\d+[.)])\s+(.*)$/.exec(line);
          const content = bulletMatch ? bulletMatch[2] : line;
          const marker = bulletMatch ? bulletMatch[1] : '•';
          const isOrdered = /^\d/.test(marker);
          return (
            <li
              key={i}
              style={{ '--indent-level': Math.floor(indentSpaces / 2) } as React.CSSProperties}
              className="flex items-baseline gap-2.5 pl-[calc(var(--indent-level,0)*1.1rem)] leading-relaxed text-zinc-200"
            >
              <span className="shrink-0 font-mono text-xs text-zinc-500 select-none">
                {isOrdered ? marker : '•'}
              </span>
              <span className="min-w-0 flex-1">
                <InlineMarkdown
                  text={content}
                  showAsides={showAsides}
                  onOpenSource={onOpenSource}
                  onNavigateAnchor={onNavigateAnchor}
                  threads={threads}
                  activeSelectionQuote={activeSelectionQuote}
                  onSelectThread={onSelectThread}
                />
              </span>
            </li>
          );
        })}
      </ul>
    );
  }

  // Standard paragraph
  return (
    <p className="leading-relaxed text-zinc-200 whitespace-pre-line">
      <InlineMarkdown
        text={markdown}
        showAsides={showAsides}
        onOpenSource={onOpenSource}
        onNavigateAnchor={onNavigateAnchor}
        threads={threads}
        activeSelectionQuote={activeSelectionQuote}
        onSelectThread={onSelectThread}
      />
    </p>
  );
};
