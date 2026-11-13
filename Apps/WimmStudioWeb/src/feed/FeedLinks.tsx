import { createContext, useContext } from 'react';
import type { InboxSource } from '../inboxTypes';
import { InlineMarkdown } from '../markdownRender';
import { sourceChip } from './feedText';

export const FeedNavigationContext = createContext<{
  onOpenSource?: (sourceId: string) => void;
  onOpenBlock?: (blockId: number) => void;
  onNavigateAnchor?: (anchor: string) => void;
}>({});

export function FeedText({ text }: { text: string }) {
  const navigation = useContext(FeedNavigationContext);
  return <span className="feed-markdown"><InlineMarkdown
    text={text.replace(/^\s*(?:[-*+]|\d+\.)\s+/, '')}
    showAsides={false}
    onOpenSource={(id) => navigation.onOpenSource ? navigation.onOpenSource(id) : window.location.assign(`/#source-${encodeURIComponent(id)}`)}
    onNavigateAnchor={(anchor) => navigation.onNavigateAnchor ? navigation.onNavigateAnchor(anchor) : window.location.assign(`/#${anchor}`)}
  /></span>;
}

export function SourceLinks({ sources }: { sources: InboxSource[] }) {
  const { onOpenSource } = useContext(FeedNavigationContext);
  if (!sources.length) return null;
  return <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap' }}>
    {sources.map((s) => <a key={s.id} href={`/#source-${encodeURIComponent(s.id)}`} title={`Открыть заметку ${s.id}`}
      onClick={onOpenSource ? (e) => { e.preventDefault(); onOpenSource(s.id); } : undefined}
      style={{ font: '600 11px var(--font-rounded)', color: 'var(--accent)', padding: '4px 10px', borderRadius: 999, background: 'var(--material-regular)' }}>
      {sourceChip(s)}
    </a>)}
  </div>;
}

export function DocumentLink({ blockId }: { blockId?: number }) {
  const { onOpenBlock } = useContext(FeedNavigationContext);
  if (blockId === undefined) return null;
  return <a href={`/#block-${blockId}`} onClick={onOpenBlock ? (e) => { e.preventDefault(); onOpenBlock(blockId); } : undefined}
    style={{ font: '600 12px var(--font-system)', padding: '0 10px', whiteSpace: 'nowrap', flex: 'none' }}>В документе</a>;
}
