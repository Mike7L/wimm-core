import { ReplyActions, type ReplyMode } from './ReplyActions';
import type { InboxSource } from '../inboxTypes';
import { FeedText, SourceLinks, DocumentLink } from './FeedLinks';
import { useEffect, useState } from 'react';
import { CloseIcon, bigTextStyle, plain } from './feedText';

export interface StoryItem {
  key: string;
  text: string;
  meta: string;
  sources: InboxSource[];
  blockId?: number;
  /** Shown under the text for a changed paragraph. */
  previous?: string;
}

export interface Story {
  id: string;
  name: string;
  letter: string;
  color: string;
  items: StoryItem[];
  replyLabel: string;
}

/** One section's changes, one at a time: tap right = next, left = back. */
export function StoryView({
  story,
  onFinish,
  onClose,
  onReply,
}: {
  story: Story;
  onFinish: () => void;
  /** Closed before the end: `seenCount` items were shown. */
  onClose: (seenCount: number) => void;
  onReply: (item: StoryItem, mode: ReplyMode) => void;
}) {
  const [index, setIndex] = useState(0);
  const [showOld, setShowOld] = useState(false);
  const item = story.items[Math.min(index, story.items.length - 1)];

  const next = () => {
    setShowOld(false);
    if (index < story.items.length - 1) setIndex(index + 1);
    else onFinish();
  };
  const prev = () => {
    setShowOld(false);
    if (index > 0) setIndex(index - 1);
  };

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'ArrowRight' || e.key === ' ') {
        e.preventDefault();
        next();
      } else if (e.key === 'ArrowLeft') prev();
      else if (e.key === 'Escape') onClose(index + 1);
    };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  });

  if (!item) return null;
  const shown = showOld && item.previous ? item.previous : item.text;

  return (
    <div role="dialog" aria-modal="true" aria-label={`История: ${story.name}`} style={{ position: 'fixed', inset: 0, zIndex: 50, display: 'flex', justifyContent: 'center', background: 'rgba(0,0,0,0.6)' }}>
      <div style={{ width: '100%', maxWidth: 'var(--feed-width)', display: 'flex', flexDirection: 'column', background: 'var(--bg-tertiary)', position: 'relative' }}>
        <div style={{ display: 'flex', gap: 4, padding: '14px 12px 0' }} aria-hidden="true">
          {story.items.length <= 40 ? (
            story.items.map((it, i) => (
              <span key={it.key} style={{ flex: 1, height: 3, borderRadius: 999, background: i <= index ? 'var(--text-primary)' : 'var(--border-hairline)' }} />
            ))
          ) : (
            <span style={{ flex: 1, height: 3, borderRadius: 999, background: 'var(--border-hairline)', overflow: 'hidden' }}>
              <span style={{ display: 'block', height: '100%', width: `${((index + 1) / story.items.length) * 100}%`, background: 'var(--text-primary)' }} />
            </span>
          )}
        </div>
        <header style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '10px 6px 0 14px', position: 'relative', zIndex: 2 }}>
          <span style={{ width: 34, height: 34, borderRadius: 999, padding: 2, boxSizing: 'border-box', flex: 'none', background: story.color }}>
            <span style={{ display: 'grid', placeItems: 'center', width: '100%', height: '100%', borderRadius: 999, background: 'var(--bg-card)', border: '2px solid var(--bg-tertiary)', boxSizing: 'border-box', font: '700 12px var(--font-rounded)' }}>
              {story.letter}
            </span>
          </span>
          <div style={{ flex: 1, minWidth: 0 }}>
            <div style={{ font: '600 14px var(--font-system)', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{story.name}</div>
            <div className="when" style={{ overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{item.meta}</div>
          </div>
          <button type="button" className="act" onClick={() => onClose(index + 1)} aria-label="Закрыть">
            <CloseIcon />
          </button>
        </header>

        <div style={{ flex: 1, minHeight: 0, position: 'relative', display: 'flex', flexDirection: 'column', justifyContent: 'center', gap: 22, padding: '0 30px' }}>
          {item.previous && (
            <div style={{ display: 'inline-flex', alignSelf: 'flex-start', gap: 2, padding: 3, borderRadius: 999, background: 'var(--bg-card)', position: 'relative', zIndex: 2 }} role="tablist" aria-label="Версия">
              <button type="button" role="tab" aria-selected={!showOld} className="seg" onClick={() => setShowOld(false)} style={!showOld ? { background: 'var(--material-regular)', color: 'var(--text-primary)' } : { background: 'transparent', color: 'var(--text-secondary)' }}>
                Стало
              </button>
              <button type="button" role="tab" aria-selected={showOld} className="seg" onClick={() => setShowOld(true)} style={showOld ? { background: 'var(--material-regular)', color: 'var(--text-primary)' } : { background: 'transparent', color: 'var(--text-secondary)' }}>
                Было
              </button>
            </div>
          )}
          <p style={{ margin: 0, letterSpacing: '-0.01em', overflowWrap: 'anywhere', position: 'relative', zIndex: 2, maxHeight: '58dvh', overflowY: 'auto', color: showOld ? 'var(--text-secondary)' : undefined, ...bigTextStyle(plain(shown), true) }}><FeedText text={shown} /></p>
          <div style={{ position: 'relative', zIndex: 2 }}><SourceLinks sources={item.sources} /><DocumentLink blockId={item.blockId} /></div>
          <button type="button" onClick={prev} aria-label="Назад" style={{ position: 'absolute', left: 0, top: 0, bottom: 0, width: '35%', border: 0, background: 'transparent', cursor: 'pointer' }} />
          <button type="button" onClick={next} aria-label="Дальше" style={{ position: 'absolute', right: 0, top: 0, bottom: 0, width: '65%', border: 0, background: 'transparent', cursor: 'pointer' }} />
        </div>
        <div style={{ textAlign: 'center', font: '400 11px var(--font-rounded)', color: 'var(--text-tertiary)', paddingBottom: 12 }}>
          {index + 1} из {story.items.length} · тап справа — дальше, слева — назад
        </div>
        <footer style={{ display: 'flex', flexWrap: 'wrap', alignItems: 'center', gap: 6, padding: '10px 12px calc(26px + env(safe-area-inset-bottom))' }}>
          <ReplyActions onReply={(mode) => onReply(item, mode)} voiceLabel={story.replyLabel} />
        </footer>
      </div>
    </div>
  );
}
