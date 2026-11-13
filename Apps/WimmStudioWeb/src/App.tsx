import { liveSource, liveState, watchLiveState, type LiveState } from './liveEvents';
import React, { useCallback, useEffect, useId, useLayoutEffect, useMemo, useRef, useState } from 'react';
import {
  Check,
  ChevronDown,
  ChevronRight,
  Edit3,
  FileText,
  GitCompareArrows,
  ListTree,
  MessageSquare,
  MessageSquarePlus,
  PanelLeftOpen,
  RefreshCw,
  Search,
  Send,
  SlidersHorizontal,
  Volume2,
  X,
} from 'lucide-react';
import {
  CommentStatus,
  CommentThread,
  DocumentBlock,
  DocumentPayload,
  REACTION_PRESETS,
  SourceDetail,
} from './types';
import { BlockBodyRenderer, InlineMarkdown, toVisiblePlainText } from './markdownRender';
import { ShouldersPanel } from './ShouldersPanel';
import { QuestionCard, loadQuestionReader, saveQuestionReader, type QuestionReaderName } from './QuestionCard';
import { DocumentChangesPanel } from './DocumentChangesPanel';
import { FeedApp } from './feed/FeedApp';
import { AppNav, VIEW_PATHS, viewFromPath, type View } from './AppNav';
import { SourceImage } from './SourceImage';
import { BlockSourceDates, SectionNewestSource } from './BlockSourceDates';

interface SelectionTarget {
  block: DocumentBlock;
  quote: string;
  prefix: string;
  suffix: string;
  x: number;
  y: number;
  bottomY: number;
}

export function App() {
  const [payload, setPayload] = useState<DocumentPayload | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [live, setLive] = useState<LiveState>('offline');

  // Screens: feed + document, dashboard, dialog
  const [view, setView] = useState<View>(() => viewFromPath(window.location.pathname));
  const previousView = useRef<View>('doc');
  const inWorkspace = view === 'feed' || view === 'doc';
  const isWide = useIsWide();
  /** Document revision the dashboard was built from; null until the dashboard is first opened. */
  const [dashboardRev, setDashboardRev] = useState<string | null>(null);
  const [feedUnread, setFeedUnread] = useState({ attention: 0, total: 0 });
  const reportUnread = useCallback((attention: number, total: number) => setFeedUnread({ attention, total }), []);
  const [feedCollapsed, setFeedCollapsed] = useState(() => loadFlag('wimm-web-feed-collapsed', false));
  // Docked beside the document from 1280px; below that it covers the text, so it always starts closed.
  const [outlineOpen, setOutlineOpen] = useState(
    () => window.innerWidth >= 1280 && loadFlag('wimm-web-outline-open', window.innerWidth >= 1536)
  );
  const [outlineTab, setOutlineTab] = useState<'toc' | 'threads'>('toc');
  const [viewMenuOpen, setViewMenuOpen] = useState(false);
  const [hintDismissed, setHintDismissed] = useState(() => loadFlag('wimm-web-hint-dismissed', false));
  useEffect(() => saveFlag('wimm-web-feed-collapsed', feedCollapsed), [feedCollapsed]);
  useEffect(() => {
    if (window.innerWidth >= 1280) saveFlag('wimm-web-outline-open', outlineOpen);
  }, [outlineOpen]);
  useEffect(() => saveFlag('wimm-web-hint-dismissed', hintDismissed), [hintDismissed]);

  // Document controls
  const [searchQuery, setSearchQuery] = useState('');
  const [showAsides, setShowAsides] = useState(true);
  const [showSourceDates, setShowSourceDates] = useState(() => loadFlag('wimm-web-source-dates', true));
  useEffect(() => saveFlag('wimm-web-source-dates', showSourceDates), [showSourceDates]);
  const [showResolved, setShowResolved] = useState(false);
  const [collapsedHeadings, setCollapsedHeadings] = useState<Set<number>>(new Set());
  const [scale, setScale] = useState(1);
  const [questionReader, setQuestionReader] = useState<QuestionReaderName>(loadQuestionReader);
  const [showChanges, setShowChanges] = useState(false);

  // Active thread & block editing
  const [activeThreadId, setActiveThreadId] = useState<string | null>(null);
  const [highlightedBlockId, setHighlightedBlockId] = useState<number | null>(null);
  const [focusedBlockId, setFocusedBlockId] = useState<number | null>(null);
  const [replyDrafts, setReplyDrafts] = useState<Record<string, string>>({});
  const [editingBlockId, setEditingBlockId] = useState<number | null>(null);
  const [editDraft, setEditDraft] = useState('');
  const editBaseSha256 = useRef<string | null>(null);

  // Text selection popover state
  const [selectionTarget, setSelectionTarget] = useState<SelectionTarget | null>(null);
  const [customCommentMode, setCustomCommentMode] = useState(false);
  const [customCommentDraft, setCustomCommentDraft] = useState('');
  const popupRef = useRef<HTMLDivElement | null>(null);
  const [popupCoords, setPopupCoords] = useState<{ left: number; top: number }>({
    left: 300,
    top: 120,
  });

  // Source [S...] dialog state
  const [sourceDetail, setSourceDetail] = useState<SourceDetail | null>(null);
  const [sourceLoading, setSourceLoading] = useState(false);
  const [sourceTab, setSourceTab] = useState<'primary' | 'attachment' | 'live' | 'runs'>('primary');
  const sourceDialogRef = useRef<HTMLDialogElement | null>(null);
  const sourceDialogTitleId = useId();
  const searchInputId = useId();

  // Which text is open: the main document or a read-only reading text.
  const [docId, setDocId] = useState(loadDocId);
  const docIdRef = useRef(docId);
  const readOnly = payload?.readOnly ?? false;
  /** A jump from the feed that waits for the main document to load. */
  const pendingDocAction = useRef<(() => void) | null>(null);

  const documentRequestId = useRef(0);
  const loadDocument = async () => {
    const requestId = ++documentRequestId.current;
    try {
      const id = docIdRef.current;
      const res = await fetch(id === 'main' ? '/api/document' : `/api/document?doc=${encodeURIComponent(id)}`, { cache: 'no-store' });
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const data: DocumentPayload = await res.json();
      if (requestId !== documentRequestId.current) return;
      setPayload(data);
      setError(null);
    } catch (e: any) {
      if (requestId === documentRequestId.current) setError(e?.message || 'Не удалось загрузить документ');
    } finally {
      if (requestId === documentRequestId.current) setLoading(false);
    }
  };

  useEffect(() => {
    loadDocument();
    const es = liveSource('events');
    const stopWatching = watchLiveState(setLive);
    es.onmessage = (ev) => {
      try {
        const msg = JSON.parse(ev.data);
        if (msg.type === 'reload' || msg.type === 'connected') {
          loadDocument();
        }
      } catch {
        // ignore
      }
    };
    const refreshOnReturn = () => {
      if (document.visibilityState === 'visible') void loadDocument();
    };
    document.addEventListener('visibilitychange', refreshOnReturn);
    const fallback = window.setInterval(() => {
      // Server unreachable: poll. A tab asleep behind another one catches up when it wakes.
      if (liveState() === 'offline') refreshOnReturn();
    }, 5000);
    return () => {
      es.close();
      stopWatching();
      window.clearInterval(fallback);
      document.removeEventListener('visibilitychange', refreshOnReturn);
    };
  }, []);

  const switchDocument = (id: string) => {
    if (id === docIdRef.current) return;
    docIdRef.current = id;
    setDocId(id);
    saveDocId(id);
    setEditingBlockId(null);
    setSelectionTarget(null);
    setActiveThreadId(null);
    setShowChanges(false);
    setSearchQuery('');
    setCollapsedHeadings(new Set());
    void loadDocument();
  };

  useEffect(() => {
    if (!payload) return;
    // The server no longer offers the remembered text: fall back to what it sent.
    if (payload.docId !== docIdRef.current && !pendingDocAction.current) {
      docIdRef.current = payload.docId;
      setDocId(payload.docId);
      saveDocId(payload.docId);
    }
    if (payload.docId === 'main' && pendingDocAction.current) {
      const action = pendingDocAction.current;
      pendingDocAction.current = null;
      requestAnimationFrame(action);
    }
  }, [payload]);

  const go = (next: View) => {
    if (next === view) return;
    if (view !== 'dialog') previousView.current = view;
    setView(next);
    window.history.pushState(null, '', VIEW_PATHS[next]);
  };

  useEffect(() => {
    const onPop = () => setView(viewFromPath(window.location.pathname));
    window.addEventListener('popstate', onPop);
    return () => window.removeEventListener('popstate', onPop);
  }, []);

  useEffect(() => {
    // The dashboard is rebuilt from the document each time the screen is opened.
    if (view === 'dashboard') setDashboardRev(payload?.sha256 ?? 'initial');
    document.title = `${VIEW_TITLES[view]} — Wimm`;
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [view]);

  // ⌘⇧D opens the dialog (Angel and Demon) and returns to the previous screen.
  useEffect(() => {
    const onKeyDown = (e: KeyboardEvent) => {
      if ((e.metaKey || e.ctrlKey) && e.shiftKey && e.key.toLowerCase() === 'd') {
        e.preventDefault();
        go(view === 'dialog' ? previousView.current : 'dialog');
      } else if (e.key === 'Escape') {
        setViewMenuOpen(false);
      }
    };
    window.addEventListener('keydown', onKeyDown);
    return () => window.removeEventListener('keydown', onKeyDown);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [view]);

  /** A link from the feed (or a TOC row) lands in the document, whatever screen is showing. */
  const showInDocument = (action: (smooth: boolean) => void) => {
    // Coming from another screen, jump straight to the place; animate only when the document is already in view.
    const documentInView = view === 'doc' || (isWide && view === 'feed');
    setShowChanges(false);
    setSearchQuery('');
    if (view !== 'doc') go('doc');
    // Feed links point into the main document.
    if (docIdRef.current !== 'main') {
      pendingDocAction.current = () => action(false);
      switchDocument('main');
      return;
    }
    action(documentInView);
  };
  const closeOutlineIfOverlay = () => {
    if (!window.matchMedia('(min-width: 1280px)').matches) setOutlineOpen(false);
  };

  // Modern Web Guidance fallback for <dialog closedby="any"> in Safari
  useEffect(() => {
    const dialog = sourceDialogRef.current;
    if (!dialog) return;

    const handleClose = () => {
      dialog.returnValue = '';
      setSourceDetail(null);
    };
    dialog.addEventListener('close', handleClose);

    if (!('closedBy' in HTMLDialogElement.prototype)) {
      const outside = (e: PointerEvent) => {
        const r = dialog.getBoundingClientRect();
        return e.clientX < r.left || e.clientX > r.right || e.clientY < r.top || e.clientY > r.bottom;
      };
      let pressedOutside = false;
      const onDown = (e: PointerEvent) => {
        pressedOutside = outside(e);
      };
      const onUp = (e: PointerEvent) => {
        if (pressedOutside && outside(e)) dialog.close();
      };
      dialog.addEventListener('pointerdown', onDown);
      dialog.addEventListener('pointerup', onUp);
      return () => {
        dialog.removeEventListener('close', handleClose);
        dialog.removeEventListener('pointerdown', onDown);
        dialog.removeEventListener('pointerup', onUp);
      };
    }

    return () => {
      dialog.removeEventListener('close', handleClose);
    };
  }, []);

  const openSourceModal = async (sourceId: string) => {
    setSourceLoading(true);
    setSourceTab('primary');
    setSourceDetail({ sourceId });
    const dialog = sourceDialogRef.current;
    if (dialog && !dialog.open) {
      dialog.showModal();
    }
    try {
      const res = await fetch(`/api/source/${encodeURIComponent(sourceId)}`);
      if (res.ok) {
        const data: SourceDetail = await res.json();
        setSourceDetail(data);
      }
    } finally {
      setSourceLoading(false);
    }
  };

  // Compute visible blocks respecting collapsed headings and search filter
  const visibleBlocks = useMemo(() => {
    if (!payload) return [];
    const out: DocumentBlock[] = [];
    let collapsedLevel: number | null = null;
    const q = searchQuery.trim().toLowerCase();

    for (const block of payload.blocks) {
      if (block.kind.type === 'hidden') continue;

      if (block.kind.type === 'heading') {
        const lvl = block.kind.level;
        if (collapsedLevel !== null && lvl <= collapsedLevel) {
          collapsedLevel = null;
        }
        if (collapsedLevel !== null) continue;
        out.push(block);
        if (collapsedHeadings.has(block.id)) {
          collapsedLevel = lvl;
        }
      } else {
        if (collapsedLevel !== null) continue;
        if (q && !block.markdown.toLowerCase().includes(q) && !(block.sectionHeading || '').toLowerCase().includes(q)) {
          continue;
        }
        out.push(block);
      }
    }
    return out;
  }, [payload, collapsedHeadings, searchQuery]);

  const headings = useMemo(() => {
    if (!payload) return [];
    const q = searchQuery.trim().toLowerCase();
    return payload.blocks.filter(
      (b) =>
        b.kind.type === 'heading' &&
        b.kind.level <= 3 &&
        (!q || b.markdown.toLowerCase().includes(q))
    );
  }, [payload, searchQuery]);

  const threadsByBlock = useMemo(() => {
    const map = new Map<number, CommentThread[]>();
    if (!payload) return map;
    for (const t of payload.threads) {
      const isClosed = t.status === 'resolved' || t.status === 'dropped';
      if (!showResolved && isClosed) continue;
      if (t.blockId !== null) {
        const arr = map.get(t.blockId) || [];
        arr.push(t);
        map.set(t.blockId, arr);
      }
    }
    return map;
  }, [payload, showResolved]);

  const filteredThreads = useMemo(() => {
    if (!payload) return [];
    const q = searchQuery.trim().toLowerCase();
    return payload.threads.filter((t) => {
      const isClosed = t.status === 'resolved' || t.status === 'dropped';
      if (!showResolved && isClosed) return false;
      if (!q) return true;
      return (
        (t.root.quote || '').toLowerCase().includes(q) ||
        (t.root.text || '').toLowerCase().includes(q) ||
        (t.root.heading || '').toLowerCase().includes(q)
      );
    }).sort((a, b) => (Date.parse(b.lastActivityAt || b.root.at) || 0) -
      (Date.parse(a.lastActivityAt || a.root.at) || 0));
  }, [payload, showResolved, searchQuery]);

  const openThreadCount = useMemo(() => {
    if (!payload) return 0;
    return payload.threads.filter((t) => t.status !== 'resolved' && t.status !== 'dropped').length;
  }, [payload]);

  // Feed deep links work on first load and when the hash changes in this reader.
  const handledHash = useRef<string | null>(null);
  useEffect(() => {
    if (!payload) return;
    const navigate = () => {
      const hash = window.location.hash;
      if (!hash || handledHash.current === hash) return;
      handledHash.current = hash;
      const block = hash.match(/^#block-(\d+)$/);
      if (hash.startsWith('#source-')) {
        void openSourceModal(decodeURIComponent(hash.slice(8)));
      } else {
        setSearchQuery('');
        setView('doc');
        if (window.location.pathname !== '/') window.history.replaceState(null, '', `/${hash}`);
        if (block) scrollToBlock(Number(block[1]));
        else navigateToAnchor(hash.slice(1));
      }
    };
    navigate();
    window.addEventListener('hashchange', navigate);
    return () => window.removeEventListener('hashchange', navigate);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [payload]);

  const scrollToBlock = (blockId: number, smooth = true) => {
    if (!payload) return;
    setShowChanges(false);
    // Uncollapse any ancestor heading
    setCollapsedHeadings((prev) => {
      const next = new Set(prev);
      for (const b of payload.blocks) {
        if (b.id > blockId) break;
        if (b.kind.type === 'heading') next.delete(b.id);
      }
      return next;
    });
    setHighlightedBlockId(blockId);
    setFocusedBlockId(blockId);
    setTimeout(() => {
      const el = document.getElementById(`doc-block-${blockId}`);
      el?.scrollIntoView({ behavior: smooth ? 'smooth' : 'auto', block: 'center' });
    }, 40);
    setTimeout(() => {
      setHighlightedBlockId((prev) => (prev === blockId ? null : prev));
    }, 2200);
  };

  const activeShouldersContext = useMemo(() => {
    if (!payload) return null;
    const targetBlock =
      (selectionTarget ? selectionTarget.block : null) ||
      (focusedBlockId !== null ? payload.blocks.find((b) => b.id === focusedBlockId) : null) ||
      payload.blocks.find((b) => b.kind.type === 'heading' && b.kind.level === 2);
    if (!targetBlock) return null;
    const heading =
      targetBlock.sectionHeading ||
      (targetBlock.kind.type === 'heading'
        ? targetBlock.markdown.replace(/^#+\s*/, '').trim()
        : undefined);
    if (!heading) return null;
    return {
      sectionId: targetBlock.sectionId,
      heading,
      excerpt:
        selectionTarget?.quote ||
        (targetBlock.kind.type === 'body' ? toVisiblePlainText(targetBlock.markdown) : undefined),
    };
  }, [payload, selectionTarget, focusedBlockId]);

  const navigateToAnchor = (anchor: string, smooth = true) => {
    if (!payload) return;
    const normalized = decodeURIComponent(anchor).trim().toLowerCase();
    const target = payload.blocks.find(
      (b) =>
        (b.anchor && b.anchor.toLowerCase() === normalized) ||
        (b.kind.type === 'heading' && (b.sectionId || '').toLowerCase() === normalized)
    );
    if (target) {
      scrollToBlock(target.id, smooth);
    }
  };

  const handleBlockMouseUp = (block: DocumentBlock) => {
    if (block.kind.type !== 'body') return;
    const sel = window.getSelection();
    if (readOnly || !sel || sel.isCollapsed || sel.rangeCount === 0) return;

    const range = sel.getRangeAt(0);
    // Extract clean text without [S...] chips or ^[aside] notes
    const fragment = range.cloneContents();
    fragment
      .querySelectorAll('[data-chip="true"], [data-aside="true"]')
      .forEach((el) => el.remove());
    const quote = (fragment.textContent || sel.toString()).replace(/\s+/g, ' ').trim();
    if (quote.length < 2) return;

    const rect = range.getBoundingClientRect();
    const plain = toVisiblePlainText(block.markdown);
    const idx = plain.indexOf(quote);
    const prefix = idx > 0 ? plain.slice(Math.max(0, idx - 32), idx) : '';
    const suffix =
      idx >= 0 ? plain.slice(idx + quote.length, idx + quote.length + 32) : '';

    setSelectionTarget({
      block,
      quote,
      prefix,
      suffix,
      x: rect.left + rect.width / 2,
      y: rect.top - 10,
      bottomY: rect.bottom + 10,
    });
    setCustomCommentMode(false);
    setCustomCommentDraft('');
  };

  const openBlockCommentBar = (block: DocumentBlock, e: React.MouseEvent) => {
    e.stopPropagation();
    const blockEl = document.getElementById(`doc-block-${block.id}`);
    const rect = (blockEl || (e.currentTarget as HTMLElement)).getBoundingClientRect();
    const quote = toVisiblePlainText(block.markdown);

    setSelectionTarget({
      block,
      quote,
      prefix: '',
      suffix: '',
      x: rect.left + rect.width / 2,
      y: rect.top - 8,
      bottomY: rect.bottom + 8,
    });
    setCustomCommentMode(true);
    setCustomCommentDraft('');
  };

  // Clamp popup position inside viewport so it never clips off screen
  useLayoutEffect(() => {
    if (!selectionTarget || !popupRef.current) return;
    const popRect = popupRef.current.getBoundingClientRect();
    const margin = 16;
    const vw = window.innerWidth;
    const vh = window.innerHeight;

    let left = selectionTarget.x - popRect.width / 2;
    left = Math.max(margin, Math.min(vw - popRect.width - margin, left));

    let top = selectionTarget.y - popRect.height;
    if (top < 56) {
      top = Math.min(vh - popRect.height - margin, selectionTarget.bottomY);
    }

    setPopupCoords({ left, top });
  }, [selectionTarget, customCommentMode]);

  const submitReactionOrComment = async (opts: {
    reaction?: string;
    intent?: string;
    text?: string;
  }) => {
    if (!selectionTarget) return;
    const { block, quote, prefix, suffix } = selectionTarget;
    setSelectionTarget(null);
    window.getSelection()?.removeAllRanges();

    await fetch('/api/threads', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        action: 'add',
        section: block.sectionId,
        heading: block.sectionHeading,
        quote,
        prefix,
        suffix,
        reaction: opts.reaction,
        intent: opts.intent,
        text: opts.text,
      }),
    });
    await loadDocument();
  };

  const submitReply = async (threadId: string) => {
    const text = (replyDrafts[threadId] || '').trim();
    if (!text) return;
    setReplyDrafts((prev) => ({ ...prev, [threadId]: '' }));
    await fetch('/api/threads', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        action: 'reply',
        threadId,
        text,
      }),
    });
    await loadDocument();
  };

  const updateThreadStatus = async (threadId: string, status: CommentStatus) => {
    await fetch('/api/threads', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        action: 'status',
        threadId,
        status,
      }),
    });
    await loadDocument();
  };

  const saveBlockEdit = async (blockId: number) => {
    if (!editBaseSha256.current) return;
    const res = await fetch('/api/block', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        blockId,
        markdown: editDraft,
        expectedSha256: editBaseSha256.current,
      }),
    });
    if (!res.ok) {
      const err = await res.json().catch(() => ({}));
      setError(err.error || 'Ошибка сохранения блока');
      return;
    }
    setEditingBlockId(null);
    await loadDocument();
  };

  const toggleHeadingCollapse = (blockId: number) => {
    setCollapsedHeadings((prev) => {
      const next = new Set(prev);
      if (next.has(blockId)) next.delete(blockId);
      else next.add(blockId);
      return next;
    });
  };

  const docTitle = useMemo(() => {
    const h1 = payload?.blocks.find((b) => b.kind.type === 'heading' && b.kind.level === 1);
    return h1 ? toVisiblePlainText(h1.markdown.replace(/^#+\s*/, '')) : pathBasename(payload?.docRelPath || 'Документ');
  }, [payload]);
  const feedVisibility = !inWorkspace ? 'invisible' : view === 'feed' ? '' : 'invisible md:visible';
  const docVisibility = !inWorkspace ? 'invisible' : view === 'doc' ? '' : 'invisible md:visible';

  return (
    <div
      style={{ '--doc-scale': scale } as React.CSSProperties}
      className="flex h-dvh w-screen flex-col overflow-hidden bg-zinc-950 text-zinc-100 md:flex-row"
      onClick={() => {
        if (selectionTarget) setSelectionTarget(null);
        if (viewMenuOpen) setViewMenuOpen(false);
      }}
    >
      <AppNav view={view} onNavigate={go} attention={feedUnread.attention} unread={feedUnread.total} live={live} />

      {/* Screens stay mounted (hidden, not removed), so scroll position and a running dialog survive a switch. */}
      <div className="relative min-h-0 min-w-0 flex-1">
        {/* Screen 1: feed + document. Side by side on a wide window, two tabs on a phone. */}
        <div className="absolute inset-0 flex">
          <section
            aria-label="Лента"
            className={`absolute inset-0 md:static md:w-[380px] md:shrink-0 md:border-r md:border-zinc-800/80 ${feedVisibility} ${
              feedCollapsed ? 'md:hidden' : ''
            }`}
          >
            <FeedApp
              embedded
              onUnreadChange={reportUnread}
              onClose={isWide ? () => setFeedCollapsed(true) : undefined}
              onOpenSource={openSourceModal}
              onNavigateAnchor={(anchor) => showInDocument((smooth) => navigateToAnchor(anchor, smooth))}
              onOpenBlock={(blockId) => showInDocument((smooth) => scrollToBlock(blockId, smooth))}
            />
          </section>

          <div className={`absolute inset-0 flex min-w-0 flex-col md:static md:flex-1 ${docVisibility}`}>
            <header className="flex h-12 shrink-0 items-center gap-1.5 border-b border-zinc-800/80 bg-zinc-900/40 px-2.5 md:px-4">
              {feedCollapsed && (
                <button
                  type="button"
                  onClick={() => setFeedCollapsed(false)}
                  title="Показать ленту"
                  aria-label={feedUnread.total > 0 ? `Показать ленту, новое: ${feedUnread.total}` : 'Показать ленту'}
                  className="relative hidden shrink-0 rounded-md p-1.5 text-zinc-400 transition hover:bg-zinc-800 hover:text-zinc-100 md:inline-flex"
                >
                  <PanelLeftOpen className="h-4 w-4" aria-hidden="true" />
                  {feedUnread.total > 0 && <span className="absolute top-0.5 right-0.5 h-2 w-2 rounded-full bg-amber-400" />}
                </button>
              )}
              <div className="hidden min-w-0 flex-col leading-tight lg:flex">
                <span className="truncate text-xs font-semibold text-zinc-100" title={payload?.docRelPath}>
                  {docTitle}
                </span>
                {payload?.modifiedAt && (
                  <time dateTime={payload.modifiedAt} className="truncate text-[10px] text-zinc-500" aria-live="polite">
                    обновлён {new Date(payload.modifiedAt).toLocaleString('ru-RU', { day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' })}
                  </time>
                )}
              </div>

              <search className="ml-auto min-w-0 flex-1 md:max-w-64">
                <label htmlFor={searchInputId} className="sr-only">
                  Поиск по документу и тредам
                </label>
                <div className="relative flex items-center">
                  <Search className="pointer-events-none absolute left-2.5 h-3.5 w-3.5 text-zinc-500" aria-hidden="true" />
                  <input
                    id={searchInputId}
                    type="search"
                    value={searchQuery}
                    onChange={(e) => setSearchQuery(e.target.value)}
                    placeholder="Найти в документе…"
                    className="w-full rounded-md border border-zinc-800 bg-zinc-950/90 py-1.5 pr-7 pl-8 text-xs text-zinc-100 placeholder:text-zinc-500 focus:border-amber-500/50 focus:outline-none"
                  />
                  {searchQuery && (
                    <button
                      type="button"
                      aria-label="Очистить поиск"
                      onClick={() => setSearchQuery('')}
                      className="absolute right-2 text-zinc-500 hover:text-zinc-300"
                    >
                      <X className="h-3.5 w-3.5" aria-hidden="true" />
                    </button>
                  )}
                </div>
              </search>

              {!readOnly && <ToolbarButton
                pressed={showChanges}
                onClick={() => setShowChanges((v) => !v)}
                label="Правки"
                title="Что секретарь изменил в документе (diff)"
              >
                <GitCompareArrows className="h-3.5 w-3.5" aria-hidden="true" />
              </ToolbarButton>}
              <ToolbarButton
                pressed={outlineOpen}
                onClick={() => setOutlineOpen((v) => !v)}
                label="Оглавление"
                title="Оглавление и треды комментариев"
                badge={openThreadCount}
              >
                <ListTree className="h-3.5 w-3.5" aria-hidden="true" />
              </ToolbarButton>

              <div className="relative shrink-0" onClick={(e) => e.stopPropagation()}>
                <ToolbarButton
                  pressed={viewMenuOpen}
                  onClick={() => setViewMenuOpen((v) => !v)}
                  label="Вид"
                  title="Вид документа: оговорки, размер текста, разделы"
                  expanded={viewMenuOpen}
                >
                  <SlidersHorizontal className="h-3.5 w-3.5" aria-hidden="true" />
                </ToolbarButton>
                {viewMenuOpen && (
                  <div
                    role="group"
                    aria-label="Вид документа"
                    className="absolute top-full right-0 z-40 mt-1.5 w-72 space-y-3 rounded-xl border border-zinc-700/90 bg-zinc-900 p-3 text-xs shadow-2xl"
                  >
                    {payload && payload.documents.length > 1 && (
                      <label className="block space-y-1.5">
                        <span className="font-medium text-zinc-100">Что читать</span>
                        <select
                          value={payload.docId}
                          onChange={(e) => switchDocument(e.target.value)}
                          className="w-full rounded-md border border-zinc-800 bg-zinc-950 px-2 py-1.5 text-zinc-100 focus:border-amber-500/50 focus:outline-none"
                        >
                          {payload.documents.map((d) => (
                            <option key={d.id} value={d.id}>
                              {d.label}
                            </option>
                          ))}
                        </select>
                        {readOnly && (
                          <span className="block text-[11px] text-zinc-500">Только чтение: без комментариев и правок.</span>
                        )}
                      </label>
                    )}

                    <label className="flex cursor-pointer items-center justify-between gap-3">
                      <span>
                        <span className="font-medium text-zinc-100">Оговорки секретаря</span>
                        <span className="block text-[11px] text-zinc-500">Пометки ^[…] внутри текста</span>
                      </span>
                      <input
                        type="checkbox"
                        checked={showAsides}
                        onChange={(e) => setShowAsides(e.target.checked)}
                        className="h-4 w-4 accent-amber-500"
                      />
                    </label>

                    <label className="flex cursor-pointer items-center justify-between gap-3">
                      <span>
                        <span className="font-medium text-zinc-100">Даты источников</span>
                        <span className="block text-[11px] text-zinc-500">Когда записано то, о чём абзац</span>
                      </span>
                      <input
                        type="checkbox"
                        checked={showSourceDates}
                        onChange={(e) => setShowSourceDates(e.target.checked)}
                        className="h-4 w-4 accent-amber-500"
                      />
                    </label>

                    <div className="flex items-center justify-between gap-3">
                      <span className="font-medium text-zinc-100">Размер текста</span>
                      <div className="flex items-center rounded-md border border-zinc-800 bg-zinc-950 px-1">
                        <button
                          type="button"
                          aria-label="Уменьшить шрифт"
                          onClick={() => setScale((s) => Math.max(0.8, Number((s - 0.1).toFixed(2))))}
                          className="px-2 py-1 text-zinc-400 hover:text-zinc-100"
                        >
                          −
                        </button>
                        <button type="button" onClick={() => setScale(1)} title="Сбросить" className="px-1.5 font-mono text-[11px] text-zinc-300">
                          {Math.round(scale * 100)}%
                        </button>
                        <button
                          type="button"
                          aria-label="Увеличить шрифт"
                          onClick={() => setScale((s) => Math.min(1.5, Number((s + 0.1).toFixed(2))))}
                          className="px-2 py-1 text-zinc-400 hover:text-zinc-100"
                        >
                          +
                        </button>
                      </div>
                    </div>

                    <div className="flex items-center justify-between gap-3">
                      <span>
                        <span className="font-medium text-zinc-100">«У меня вопрос»</span>
                        <span className="block text-[11px] text-zinc-500">Кто читает документ для ответа</span>
                      </span>
                      <div
                        role="group"
                        aria-label="Кто читает документ для «У меня вопрос»"
                        title="web — разбор Studio, cli — читатель секретаря (wimm-cli doc)"
                        className="inline-flex shrink-0 overflow-hidden rounded-md border border-zinc-700/90"
                      >
                        {(['web', 'cli'] as QuestionReaderName[]).map((r) => (
                          <button
                            key={r}
                            type="button"
                            aria-pressed={questionReader === r}
                            onClick={() => {
                              setQuestionReader(r);
                              saveQuestionReader(r);
                            }}
                            className={`px-2.5 py-1 font-mono transition ${
                              questionReader === r ? 'bg-amber-500/20 text-amber-200' : 'bg-zinc-950 text-zinc-400 hover:text-zinc-200'
                            }`}
                          >
                            {r}
                          </button>
                        ))}
                      </div>
                    </div>

                    <div className="flex gap-2 border-t border-zinc-800 pt-3">
                      <button
                        type="button"
                        onClick={() => {
                          if (!payload) return;
                          setCollapsedHeadings(
                            collapsedHeadings.size > 0
                              ? new Set()
                              : new Set(payload.blocks.filter((b) => b.kind.type === 'heading' && b.kind.level >= 2).map((b) => b.id))
                          );
                        }}
                        className="flex-1 rounded-md border border-zinc-800 bg-zinc-950 px-2.5 py-1.5 text-zinc-300 transition hover:border-zinc-700 hover:text-zinc-100"
                      >
                        {collapsedHeadings.size > 0 ? 'Развернуть всё' : 'Свернуть разделы'}
                      </button>
                      <button
                        type="button"
                        onClick={loadDocument}
                        className="inline-flex items-center gap-1.5 rounded-md border border-zinc-800 bg-zinc-950 px-2.5 py-1.5 text-zinc-300 transition hover:border-zinc-700 hover:text-zinc-100"
                      >
                        <RefreshCw className="h-3.5 w-3.5" aria-hidden="true" />
                        Обновить
                      </button>
                    </div>

                    {payload && (
                      <p className="truncate font-mono text-[10px] text-zinc-500" title={payload.docRelPath}>
                        {pathBasename(payload.docRelPath)} · {payload.blocks.length} блоков · {payload.sourceCount} источн.
                      </p>
                    )}
                  </div>
                )}
              </div>
            </header>

              {error && (
                <div className="flex items-center justify-between border-b border-red-500/30 bg-red-500/10 px-5 py-2 text-xs text-red-200">
                  <span>{error}</span>
                  <button
                    type="button"
                    onClick={() => setError(null)}
                    className="underline hover:text-white"
                  >
                    Скрыть
                  </button>
                </div>
              )}


            <div className="relative flex min-h-0 flex-1">
              {/* Document Scroll View */}
              <main className="min-w-0 flex-1 overflow-y-auto px-4 py-6 md:px-6 md:py-8">
                {showChanges ? <DocumentChangesPanel revision={payload?.sha256} /> : loading ? (
                  <div className="mx-auto max-w-3xl space-y-4 py-12">
                    <div className="h-7 w-1/2 animate-pulse rounded bg-zinc-800/70" />
                    <div className="h-24 w-full animate-pulse rounded bg-zinc-900" />
                    <div className="h-24 w-full animate-pulse rounded bg-zinc-900" />
                  </div>
                ) : (
                  <div className="mx-auto max-w-3xl space-y-4 text-[calc(0.95rem*var(--doc-scale,1))]">
              {!hintDismissed && (
                <div className="flex items-start gap-2 rounded-lg border border-zinc-800/80 bg-zinc-900/40 px-3.5 py-2 text-xs text-zinc-400">
                  <p className="min-w-0 flex-1">
                    Выделите фразу, чтобы поставить реакцию ({REACTION_PRESETS.map((r) => r.emoji).join(' ')}) или оставить
                    комментарий секретарю. Чип{' '}
                    <span className="rounded bg-sky-500/15 px-1 py-0.5 font-mono text-[11px] text-sky-300">S…</span>{' '}
                    открывает исходную заметку и аудио.
                  </p>
                  <button
                    type="button"
                    aria-label="Скрыть подсказку"
                    onClick={() => setHintDismissed(true)}
                    className="shrink-0 rounded p-0.5 text-zinc-500 hover:bg-zinc-800 hover:text-zinc-200"
                  >
                    <X className="h-3.5 w-3.5" aria-hidden="true" />
                  </button>
                </div>
              )}

                    {visibleBlocks.map((block) => {
                      const blockThreads = threadsByBlock.get(block.id) || [];
                      const isHighlighted = highlightedBlockId === block.id;

                      // Editorial metadata block (**Редакция: ...)
                      if (block.kind.type === 'body' && block.markdown.startsWith('**Редакция:')) {
                        return (
                          <details
                            key={block.id}
                            id={`doc-block-${block.id}`}
                            className="rounded-lg border border-zinc-800/80 bg-zinc-900/30 px-4 py-2.5 text-xs text-zinc-400"
                          >
                            <summary className="cursor-pointer font-medium text-zinc-300 select-none">
                              О документе (метаданные редакции)
                            </summary>
                            <div className="mt-2 border-t border-zinc-800/80 pt-2">
                              <BlockBodyRenderer
                                markdown={block.markdown}
                                showAsides={showAsides}
                                onOpenSource={openSourceModal}
                                onNavigateAnchor={navigateToAnchor}
                              />
                            </div>
                          </details>
                        );
                      }

                      // Heading block
                      if (block.kind.type === 'heading') {
                        const lvl = block.kind.level;
                        const title = block.markdown.replace(/^#+\s*/, '').trim();
                        const isCollapsed = collapsedHeadings.has(block.id);

                        if (lvl === 1) {
                          return (
                            <h1
                              key={block.id}
                              id={`doc-block-${block.id}`}
                              className="mt-4 border-b border-zinc-800 pb-3 text-2xl font-bold tracking-tight text-zinc-50"
                            >
                              {title}
                            </h1>
                          );
                        }

                        const HeadingTag = lvl === 2 ? 'h2' : 'h3';
                        return (
                          <div
                            key={block.id}
                            id={`doc-block-${block.id}`}
                            className={`pt-4 ${isHighlighted ? 'rounded-lg bg-amber-500/10 px-2' : ''}`}
                          >
                            <HeadingTag
                              className={
                                lvl === 2
                                  ? 'text-lg font-bold text-zinc-100'
                                  : 'text-base font-semibold text-zinc-200'
                              }
                            >
                              <button
                                type="button"
                                aria-expanded={!isCollapsed}
                                onClick={() => toggleHeadingCollapse(block.id)}
                                className="group flex w-full items-center gap-2 text-left hover:text-amber-200"
                              >
                                {isCollapsed ? (
                                  <ChevronRight
                                    className="h-4 w-4 shrink-0 text-zinc-500 group-hover:text-amber-300"
                                    aria-hidden="true"
                                  />
                                ) : (
                                  <ChevronDown
                                    className="h-4 w-4 shrink-0 text-zinc-500 group-hover:text-amber-300"
                                    aria-hidden="true"
                                  />
                                )}
                                <span>
                                  <InlineMarkdown
                                    text={title}
                                    showAsides={showAsides}
                                    onOpenSource={openSourceModal}
                                    onNavigateAnchor={navigateToAnchor}
                                  />
                                </span>
                                {showSourceDates && block.sourceDates && (
                                  <SectionNewestSource dates={block.sourceDates} />
                                )}
                              </button>
                            </HeadingTag>
                          </div>
                        );
                      }

                      // Body block
                      return (
                        <div
                          key={block.id}
                          id={`doc-block-${block.id}`}
                          onMouseUp={() => handleBlockMouseUp(block)}
                          className={`group relative rounded-lg px-3 py-2 transition ${
                            isHighlighted
                              ? 'bg-amber-500/15 ring-1 ring-amber-500/40'
                              : 'hover:bg-zinc-900/50'
                          }`}
                        >
                          {editingBlockId === block.id ? (
                            <div className="space-y-2">
                              <textarea
                                value={editDraft}
                                onChange={(e) => setEditDraft(e.target.value)}
                                rows={Math.max(4, editDraft.split('\n').length + 1)}
                                className="w-full rounded-lg border border-zinc-700 bg-zinc-900 p-3 font-mono text-xs leading-relaxed text-zinc-100 focus:border-amber-500 focus:outline-none"
                              />
                              <div className="flex justify-end gap-2">
                                <button
                                  type="button"
                                  onClick={() => setEditingBlockId(null)}
                                  className="rounded-md border border-zinc-700 px-3 py-1 text-xs text-zinc-300 hover:bg-zinc-800"
                                >
                                  Отмена
                                </button>
                                <button
                                  type="button"
                                  onClick={() => saveBlockEdit(block.id)}
                                  className="rounded-md bg-amber-500 px-3 py-1 text-xs font-semibold text-zinc-950 hover:bg-amber-400"
                                >
                                  Сохранить в Markdown
                                </button>
                              </div>
                            </div>
                          ) : (
                            <div className="flex items-start gap-3">
                              <div className="min-w-0 flex-1">
                                <BlockBodyRenderer
                                  markdown={block.markdown}
                                  showAsides={showAsides}
                                  onOpenSource={openSourceModal}
                                  onNavigateAnchor={navigateToAnchor}
                                  threads={blockThreads}
                                  activeSelectionQuote={
                                    selectionTarget?.block.id === block.id
                                      ? selectionTarget.quote
                                      : null
                                  }
                                  onSelectThread={(tid) => setActiveThreadId(tid)}
                                />
                                {showSourceDates && block.sourceDates && (
                                  <BlockSourceDates dates={block.sourceDates} />
                                )}

                                {/* Cited image thumbnails below the paragraph (like StudioCitedImages) */}
                                {block.citedImages && block.citedImages.length > 0 && (
                                  <div className="mt-2.5 flex flex-wrap gap-2">
                                    {block.citedImages.map((img) => (
                                      <button
                                        key={`${img.sourceId}-${img.path}`}
                                        type="button"
                                        onClick={(e) => {
                                          e.stopPropagation();
                                          openSourceModal(img.sourceId);
                                        }}
                                        className="group/img relative overflow-hidden rounded-lg border border-zinc-800 bg-zinc-900 transition hover:border-sky-500/50"
                                      >
                                        <SourceImage path={img.path} alt={`Фото источника ${img.sourceId}`} thumbnail />
                                        <span className="absolute right-1.5 bottom-1.5 rounded bg-zinc-950/80 px-1.5 py-0.5 font-mono text-[10px] font-medium text-sky-300">
                                          {img.sourceId}
                                        </span>
                                      </button>
                                    ))}
                                  </div>
                                )}
                              </div>

                              {/* Quick hover action buttons on paragraph right margin */}
                              <div className={`${readOnly ? 'hidden' : 'flex'} shrink-0 items-center gap-1 opacity-0 transition group-hover:opacity-100 focus-within:opacity-100`}>
                                <button
                                  type="button"
                                  aria-label="Реакция или комментарий к абзацу"
                                  onClick={(e) => openBlockCommentBar(block, e)}
                                  className="rounded p-1 text-zinc-500 hover:bg-zinc-800 hover:text-amber-300"
                                >
                                  <MessageSquarePlus className="h-3.5 w-3.5" aria-hidden="true" />
                                </button>
                                <button
                                  type="button"
                                  aria-label="Редактировать Markdown абзаца"
                                  onClick={() => {
                                    editBaseSha256.current = payload?.sha256 ?? null;
                                    setEditingBlockId(block.id);
                                    setEditDraft(block.markdown);
                                  }}
                                  className="rounded p-1 text-zinc-500 hover:bg-zinc-800 hover:text-zinc-200"
                                >
                                  <Edit3 className="h-3.5 w-3.5" aria-hidden="true" />
                                </button>
                              </div>
                            </div>
                          )}

                          {/* Attached threads for this block */}
                          {blockThreads.length > 0 && (
                            <div className="mt-2.5 space-y-2 border-l-2 border-amber-500/40 pl-3">
                              {blockThreads.map((t) => (
                                <div
                                  key={t.id}
                                  className={`rounded-lg border p-3 text-xs transition ${
                                    activeThreadId === t.id
                                      ? 'border-amber-500/50 bg-zinc-900'
                                      : 'border-zinc-800/90 bg-zinc-900/70'
                                  }`}
                                >
                                  <div className="flex items-center justify-between gap-2">
                                    <div className="flex items-center gap-2 min-w-0">
                                      <span className="text-base">{t.root.reaction || '💬'}</span>
                                      {t.root.quote && (
                                        <span className="truncate italic text-zinc-400">
                                          «{t.root.quote}»
                                        </span>
                                      )}
                                    </div>
                                    <div className="flex items-center gap-1.5 shrink-0">
                                      <span className="rounded-full bg-zinc-800 px-2 py-0.5 text-[10px] font-medium text-zinc-300">
                                        {t.status}
                                      </span>
                                      {t.status !== 'resolved' && (
                                        <button
                                          type="button"
                                          onClick={() => updateThreadStatus(t.id, 'resolved')}
                                          className="inline-flex items-center gap-1 rounded bg-emerald-500/15 px-2 py-0.5 text-[11px] font-medium text-emerald-300 hover:bg-emerald-500/25"
                                        >
                                          <Check className="h-3 w-3" aria-hidden="true" />
                                          Resolve
                                        </button>
                                      )}
                                      {t.status !== 'dropped' && (
                                        <button
                                          type="button"
                                          onClick={() => updateThreadStatus(t.id, 'dropped')}
                                          className="rounded bg-zinc-800 px-2 py-0.5 text-[11px] text-zinc-400 hover:bg-zinc-700 hover:text-zinc-200"
                                        >
                                          Drop
                                        </button>
                                      )}
                                    </div>
                                  </div>

                                  {t.root.text && (
                                    <p className="mt-1.5 text-zinc-100">{t.root.text}</p>
                                  )}

                                  {t.replies.length > 0 && (
                                    <div className="mt-2 space-y-1.5 border-t border-zinc-800/80 pt-2">
                                      {t.replies.map((r) => (
                                        <div key={r.id} className="text-xs">
                                          <span
                                            className={`mr-1.5 font-semibold ${
                                              r.author === 'secretary'
                                                ? 'text-sky-400'
                                                : 'text-amber-300'
                                            }`}
                                          >
                                            {r.author === 'secretary' ? 'Секретарь:' : 'Вы:'}
                                          </span>
                                          <span className="text-zinc-200">{r.text}</span>
                                        </div>
                                      ))}
                                    </div>
                                  )}

                                  {/* Reply input */}
                                  <div className="mt-2 flex items-center gap-2">
                                    <input
                                      type="text"
                                      value={replyDrafts[t.id] || ''}
                                      onChange={(e) =>
                                        setReplyDrafts((prev) => ({ ...prev, [t.id]: e.target.value }))
                                      }
                                      onKeyDown={(e) => {
                                        if (e.key === 'Enter') submitReply(t.id);
                                      }}
                                      placeholder="Ответить в тред…"
                                      className="flex-1 rounded border border-zinc-800 bg-zinc-950 px-2.5 py-1 text-xs text-zinc-100 placeholder:text-zinc-500 focus:border-amber-500/50 focus:outline-none"
                                    />
                                    <button
                                      type="button"
                                      onClick={() => submitReply(t.id)}
                                      className="inline-flex items-center gap-1 rounded bg-zinc-800 px-2.5 py-1 text-xs font-medium text-zinc-200 hover:bg-zinc-700"
                                    >
                                      <Send className="h-3 w-3" aria-hidden="true" />
                                      Ответить
                                    </button>
                                  </div>
                                </div>
                              ))}
                            </div>
                          )}
                        </div>
                      );
                    })}
                  </div>
                )}
              </main>

            {outlineOpen && (
              <aside
                aria-label="Оглавление и треды"
                className="absolute inset-y-0 right-0 z-20 flex w-full max-w-xs flex-col border-l border-zinc-800/80 bg-zinc-900 shadow-2xl xl:static xl:w-72 xl:shrink-0 xl:bg-zinc-900/50 xl:shadow-none"
              >
                <div className="flex items-center gap-1 border-b border-zinc-800/80 p-1 text-xs font-medium">
                  <button
                    type="button"
                    onClick={() => setOutlineTab('toc')}
                    aria-pressed={outlineTab === 'toc'}
                    className={`flex flex-1 items-center justify-center gap-1.5 rounded py-1.5 transition ${
                      outlineTab === 'toc' ? 'bg-zinc-800 text-zinc-100' : 'text-zinc-400 hover:text-zinc-200'
                    }`}
                  >
                    <ListTree className="h-3.5 w-3.5" aria-hidden="true" />
                    <span>Оглавление</span>
                  </button>
                  <button
                    type="button"
                    onClick={() => setOutlineTab('threads')}
                    aria-pressed={outlineTab === 'threads'}
                    className={`flex flex-1 items-center justify-center gap-1.5 rounded py-1.5 transition ${
                      outlineTab === 'threads' ? 'bg-zinc-800 text-zinc-100' : 'text-zinc-400 hover:text-zinc-200'
                    }`}
                  >
                    <MessageSquare className="h-3.5 w-3.5" aria-hidden="true" />
                    <span>Треды · {openThreadCount}</span>
                  </button>
                  <button
                    type="button"
                    aria-label="Закрыть оглавление"
                    onClick={() => setOutlineOpen(false)}
                    className="rounded p-1.5 text-zinc-400 hover:bg-zinc-800 hover:text-zinc-100"
                  >
                    <X className="h-3.5 w-3.5" aria-hidden="true" />
                  </button>
                </div>
                <nav
                  aria-label={outlineTab === 'toc' ? 'Оглавление документа' : 'Список тредов'}
                  className="flex-1 overflow-y-auto p-2"
                >
                {outlineTab === 'toc' ? (
                  <ul className="space-y-0.5">
                    {headings.map((h) => {
                      const lvl = h.kind.type === 'heading' ? h.kind.level : 2;
                      const title = h.markdown.replace(/^#+\s*/, '').trim();
                      const sectionThreads =
                        payload?.threads.filter(
                          (t) =>
                            t.status !== 'resolved' &&
                            t.status !== 'dropped' &&
                            (t.root.section === h.sectionId || t.root.heading === title)
                        ).length || 0;

                      return (
                        <li key={h.id}>
                          <button
                            type="button"
                            onClick={() => {
                              scrollToBlock(h.id);
                              closeOutlineIfOverlay();
                            }}
                            style={{ '--toc-indent': Math.max(0, lvl - 1) } as React.CSSProperties}
                            className="group flex w-full items-center justify-between gap-2 rounded-md px-2.5 py-1.5 pl-[calc(0.625rem+var(--toc-indent,0)*0.75rem)] text-left text-xs text-zinc-300 transition hover:bg-zinc-800/70 hover:text-zinc-100"
                          >
                            <span
                              className={`truncate ${
                                lvl === 1
                                  ? 'font-bold text-zinc-100'
                                  : lvl === 2
                                    ? 'font-medium text-zinc-200'
                                    : 'text-zinc-400'
                              }`}
                            >
                              {title}
                            </span>
                            {sectionThreads > 0 && (
                              <span className="shrink-0 rounded-full bg-amber-500/20 px-1.5 py-0.2 font-mono text-[10px] font-semibold text-amber-300">
                                {sectionThreads}
                              </span>
                            )}
                          </button>
                        </li>
                      );
                    })}
                  </ul>
                ) : (
                  <div className="space-y-2">
                    <div className="flex items-center justify-between px-1 py-1 text-[11px] text-zinc-400">
                      <span>Показано: {filteredThreads.length}</span>
                      <label className="flex cursor-pointer items-center gap-1.5 select-none">
                        <input
                          type="checkbox"
                          checked={showResolved}
                          onChange={(e) => setShowResolved(e.target.checked)}
                          className="rounded border-zinc-700 bg-zinc-900 text-amber-500"
                        />
                        <span>Включая закрытые</span>
                      </label>
                    </div>
                    <ul className="space-y-2">
                      {filteredThreads.map((t) => (
                        <li key={t.id}>
                          <button
                            type="button"
                            onClick={() => {
                              setActiveThreadId(t.id);
                              if (t.blockId !== null) scrollToBlock(t.blockId);
                              closeOutlineIfOverlay();
                            }}
                            className={`w-full rounded-lg border p-2.5 text-left transition ${
                              activeThreadId === t.id
                                ? 'border-amber-500/60 bg-amber-500/10'
                                : 'border-zinc-800/90 bg-zinc-900/60 hover:border-zinc-700'
                            }`}
                          >
                            <div className="flex items-center justify-between gap-2">
                              <span className="inline-flex items-center gap-1.5 text-xs font-medium text-zinc-200">
                                <span>{t.root.reaction || '💬'}</span>
                                <span className="truncate text-[11px] text-zinc-400">
                                  {t.root.heading || t.root.section || 'Без раздела'}
                                </span>
                              </span>
                              <span
                                className={`rounded-full px-1.5 py-0.5 text-[10px] font-medium ${
                                  t.status === 'open'
                                    ? 'bg-amber-500/20 text-amber-300'
                                    : t.status === 'answered'
                                      ? 'bg-sky-500/20 text-sky-300'
                                      : 'bg-zinc-800 text-zinc-400'
                                }`}
                              >
                                {t.status}
                              </span>
                            </div>
                            {t.lastActivityAt && (
                              <time dateTime={t.lastActivityAt} className="mt-1 block text-[10px] text-zinc-400">
                                {new Date(t.lastActivityAt).toLocaleString('ru-RU')}
                              </time>
                            )}
                            {t.root.quote && (
                              <p className="mt-1.5 line-clamp-2 border-l-2 border-zinc-700 pl-2 text-[11px] italic text-zinc-400">
                                «{t.root.quote}»
                              </p>
                            )}
                            {t.root.text && (
                              <p className="mt-1 line-clamp-2 text-xs text-zinc-200">{t.root.text}</p>
                            )}
                            {t.replies.length > 0 && (
                              <p className="mt-1 text-[11px] text-sky-400">
                                Ответов: {t.replies.length} (посл.: {t.replies[t.replies.length - 1].author})
                              </p>
                            )}
                          </button>
                        </li>
                      ))}
                    </ul>
                  </div>
                )}
                </nav>
              </aside>
            )}
            </div>
          </div>
        </div>

        {/* Screen 2: dashboard, built by the server from the document. */}
        {dashboardRev !== null && (
          <iframe
            key={dashboardRev}
            src="/dashboard?raw=1"
            title="Дашборд"
            className={`absolute inset-0 h-full w-full border-0 bg-zinc-950 ${view === 'dashboard' ? '' : 'invisible'}`}
          />
        )}

        {/* Screen 3: dialog — Angel and Demon argue over the document's dossier. */}
        <div className={`absolute inset-0 bg-zinc-950 ${view === 'dialog' ? '' : 'invisible'}`}>
          <ShouldersPanel
            variant="page"
            open={view === 'dialog'}
            onClose={() => go(previousView.current)}
            activeContext={activeShouldersContext}
            onSaveInsight={async ({ speaker, text, section, heading }) => {
              await fetch('/api/threads', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({
                  action: 'add',
                  section,
                  heading,
                  reaction: speaker === 'angel' ? '😇' : '😈',
                  text: `${speaker === 'angel' ? 'Ангел' : 'Демон'}: ${text}`,
                }),
              });
              await loadDocument();
            }}
          />
        </div>
      </div>

      {/* Voice command «У меня вопрос …» → one-shot answer */}
      <QuestionCard reader={questionReader} />

      {/* Floating Selection Reaction Bar */}
      {selectionTarget && (
        <div
          ref={popupRef}
          style={
            {
              '--pop-left': `${popupCoords.left}px`,
              '--pop-top': `${popupCoords.top}px`,
            } as React.CSSProperties
          }
          onClick={(e) => e.stopPropagation()}
          className="fixed top-[var(--pop-top)] left-[var(--pop-left)] z-50 w-max max-w-[calc(100vw-32px)] rounded-xl border border-zinc-700/90 bg-zinc-900/95 p-2.5 shadow-2xl backdrop-blur-md"
        >
          <div className="mb-1.5 flex items-center justify-between gap-3 border-b border-zinc-800/80 pb-1 text-[11px] text-zinc-400">
            <span className="max-w-xs truncate italic">
              «{selectionTarget.quote}»
            </span>
            <button
              type="button"
              aria-label="Закрыть панель реакций"
              onClick={() => setSelectionTarget(null)}
              className="text-zinc-500 hover:text-zinc-300"
            >
              <X className="h-3.5 w-3.5" aria-hidden="true" />
            </button>
          </div>
          <div className="flex flex-wrap items-center gap-1">
            {REACTION_PRESETS.map((preset) => (
              <button
                key={preset.intent}
                type="button"
                aria-label={`${preset.label}: ${preset.instruction}`}
                onClick={() =>
                  submitReactionOrComment({
                    reaction: preset.emoji,
                    intent: preset.intent,
                  })
                }
                className="flex flex-col items-center rounded-lg px-2 py-1 transition hover:bg-zinc-800"
              >
                <span className="text-base leading-none">{preset.emoji}</span>
                <span className="mt-1 text-[9px] text-zinc-400">{preset.label}</span>
              </button>
            ))}
            <div className="mx-1 h-6 w-px bg-zinc-800" />
            <button
              type="button"
              onClick={() => setCustomCommentMode((v) => !v)}
              className={`rounded-lg px-2.5 py-1.5 text-xs font-medium transition ${
                customCommentMode
                  ? 'bg-amber-500 text-zinc-950'
                  : 'bg-zinc-800 text-zinc-200 hover:bg-zinc-700'
              }`}
            >
              💬 Комментарий
            </button>
          </div>

          {customCommentMode && (
            <div className="mt-2 flex items-center gap-1.5 border-t border-zinc-800 pt-2">
              <input
                type="text"
                autoFocus
                value={customCommentDraft}
                onChange={(e) => setCustomCommentDraft(e.target.value)}
                onKeyDown={(e) => {
                  if (e.key === 'Enter' && customCommentDraft.trim()) {
                    submitReactionOrComment({ text: customCommentDraft.trim() });
                  } else if (e.key === 'Escape') {
                    setSelectionTarget(null);
                  }
                }}
                placeholder="Напишите комментарий к выделенному…"
                className="min-w-0 flex-1 rounded-md border border-zinc-700 bg-zinc-950 px-2.5 py-1.5 text-xs text-zinc-100 placeholder:text-zinc-500 focus:border-amber-500 focus:outline-none"
              />
              <button
                type="button"
                disabled={!customCommentDraft.trim()}
                onClick={() =>
                  submitReactionOrComment({ text: customCommentDraft.trim() })
                }
                className="shrink-0 rounded-md bg-amber-500 px-3 py-1.5 text-xs font-semibold text-zinc-950 hover:bg-amber-400 disabled:opacity-40"
              >
                Отправить
              </button>
            </div>
          )}
        </div>
      )}

      {/* Native Modal Dialog for [S...] Source Inspection (Modern Web Guidance compliant) */}
      <dialog
        ref={sourceDialogRef}
        {...({ closedby: 'any' } as any)}
        aria-labelledby={sourceDialogTitleId}
        className="m-auto w-full max-w-2xl rounded-2xl border border-zinc-800 bg-zinc-900 p-0 text-zinc-100 shadow-2xl"
      >
        <div className="flex items-center justify-between border-b border-zinc-800 px-5 py-3.5">
          <div className="flex items-center gap-2.5">
            <FileText className="h-4 w-4 text-sky-400" aria-hidden="true" />
            <h2 id={sourceDialogTitleId} className="font-mono text-sm font-bold text-zinc-100">
              Источник [{sourceDetail?.sourceId}]
            </h2>
            {sourceDetail?.status && (
              <span className="rounded-full bg-zinc-800 px-2 py-0.5 text-[11px] font-medium text-zinc-300">
                {sourceDetail.status}
              </span>
            )}
          </div>
          <form method="dialog">
            <button
              type="submit"
              value="close"
              aria-label="Закрыть окно источника"
              autoFocus
              className="rounded-lg p-1 text-zinc-400 hover:bg-zinc-800 hover:text-zinc-100"
            >
              <X className="h-4 w-4" aria-hidden="true" />
            </button>
          </form>
        </div>

        <div className="max-h-[75vh] space-y-4 overflow-y-auto p-5 text-xs">
          {sourceLoading ? (
            <div className="space-y-3 py-6">
              <div className="h-4 w-1/3 animate-pulse rounded bg-zinc-800" />
              <div className="h-24 w-full animate-pulse rounded bg-zinc-800/60" />
            </div>
          ) : sourceDetail ? (
            <>
              {sourceDetail.reason && (
                <div className="rounded-lg border border-zinc-800 bg-zinc-950/60 p-3 text-zinc-300">
                  <span className="font-semibold text-zinc-400">Заметка секретаря: </span>
                  {sourceDetail.reason}
                </div>
              )}

              {(sourceDetail.audioPaths ?? (
                sourceDetail.recordingPath && sourceDetail.mediaKind === 'audio'
                  ? [sourceDetail.recordingPath] : []
              )).map((audioPath) => (
                <div key={audioPath} className="rounded-lg border border-zinc-800 bg-zinc-950 p-3">
                  <div className="mb-2 flex items-center gap-2 text-zinc-400">
                    <Volume2 className="h-3.5 w-3.5 text-amber-400" aria-hidden="true" />
                    <span>Аудиозапись ({pathBasename(audioPath)})</span>
                  </div>
                  <audio
                    controls
                    preload="metadata"
                    src={`/api/media?path=${encodeURIComponent(audioPath)}`}
                    className="w-full"
                  />
                </div>
              ))}

              {(sourceDetail.imagePaths && sourceDetail.imagePaths.length > 0
                ? sourceDetail.imagePaths
                : sourceDetail.recordingPath && sourceDetail.mediaKind === 'image'
                  ? [sourceDetail.recordingPath]
                  : []
              ).map((imgPath, idx) => (
                <div
                  key={idx}
                  className="overflow-hidden rounded-lg border border-zinc-800 bg-zinc-950 p-2"
                >
                  <SourceImage key={imgPath} path={imgPath} alt={`Вложение источника ${sourceDetail.sourceId}`} />
                </div>
              ))}

              {(sourceDetail.documentPaths ?? (
                sourceDetail.recordingPath && sourceDetail.mediaKind === 'pdf'
                  ? [sourceDetail.recordingPath] : []
              )).map((documentPath) => {
                const mediaUrl = `/api/media?path=${encodeURIComponent(documentPath)}`;
                const isPdf = documentPath.toLowerCase().endsWith('.pdf');
                const name = pathBasename(documentPath);
                return (
                  <div key={documentPath} className="rounded-lg border border-zinc-800 bg-zinc-950 p-3">
                    <div className="mb-2 flex flex-wrap items-center justify-between gap-2 text-zinc-300">
                      <span>{name}</span>
                      <a href={`${mediaUrl}&download=1`} className="text-cyan-400 underline">Скачать оригинал</a>
                    </div>
                    {isPdf ? (
                      <object data={mediaUrl} type="application/pdf" aria-label={`Предпросмотр ${name}`}
                        className="h-[65vh] min-h-80 w-full rounded bg-white">
                        <p className="p-3">Браузер не поддерживает просмотр PDF. <a href={mediaUrl} target="_blank" rel="noreferrer" className="text-cyan-400 underline">Открыть PDF</a></p>
                      </object>
                    ) : (
                      <>
                        <p className="mb-2 text-xs text-zinc-400">Текстовый предпросмотр</p>
                        <iframe src={`${mediaUrl}&preview=text`} title={`Текст документа ${name}`}
                          sandbox="" className="h-80 w-full rounded bg-white" />
                      </>
                    )}
                  </div>
                );
              })}

              {/* Transcript view tabs */}
              <div className="flex gap-1 border-b border-zinc-800 pb-2">
                <button
                  type="button"
                  onClick={() => setSourceTab('primary')}
                  className={`rounded-md px-2.5 py-1 font-medium ${
                    sourceTab === 'primary'
                      ? 'bg-zinc-800 text-zinc-100'
                      : 'text-zinc-400 hover:text-zinc-200'
                  }`}
                >
                  Текст заметки
                </button>
                {sourceDetail.attachmentText && (
                  <button
                    type="button"
                    onClick={() => setSourceTab('attachment')}
                    className={`rounded-md px-2.5 py-1 font-medium ${
                      sourceTab === 'attachment'
                        ? 'bg-zinc-800 text-zinc-100'
                        : 'text-zinc-400 hover:text-zinc-200'
                    }`}
                  >
                    Текст вложений / OCR
                  </button>
                )}
                {sourceDetail.liveTranscript && (
                  <button
                    type="button"
                    onClick={() => setSourceTab('live')}
                    className={`rounded-md px-2.5 py-1 font-medium ${
                      sourceTab === 'live'
                        ? 'bg-zinc-800 text-zinc-100'
                        : 'text-zinc-400 hover:text-zinc-200'
                    }`}
                  >
                    Live-текст (во время записи)
                  </button>
                )}
                {sourceDetail.previousRuns && sourceDetail.previousRuns.length > 0 && (
                  <button
                    type="button"
                    onClick={() => setSourceTab('runs')}
                    className={`rounded-md px-2.5 py-1 font-medium ${
                      sourceTab === 'runs'
                        ? 'bg-zinc-800 text-zinc-100'
                        : 'text-zinc-400 hover:text-zinc-200'
                    }`}
                  >
                    Прошлые прогоны ({sourceDetail.previousRuns.length})
                  </button>
                )}
              </div>

              {sourceTab === 'primary' && (
                <div className="rounded-lg border border-zinc-800 bg-zinc-950 p-3.5 leading-relaxed whitespace-pre-wrap text-zinc-200">
                  {sourceDetail.primaryText || 'Текст заметки не найден в локальной библиотеке.'}
                </div>
              )}

              {sourceTab === 'attachment' && (
                <div className="rounded-lg border border-zinc-800 bg-zinc-950 p-3.5 leading-relaxed whitespace-pre-wrap text-zinc-300">
                  {sourceDetail.attachmentText}
                </div>
              )}

              {sourceTab === 'live' && (
                <div className="rounded-lg border border-zinc-800 bg-zinc-950 p-3.5 leading-relaxed whitespace-pre-wrap text-zinc-300">
                  {sourceDetail.liveTranscript}
                </div>
              )}

              {sourceTab === 'runs' && (
                <div className="space-y-2">
                  {sourceDetail.previousRuns?.map((run, i) => (
                    <div
                      key={i}
                      className="rounded-lg border border-zinc-800 bg-zinc-950 p-3 text-zinc-300"
                    >
                      <div className="mb-1 font-mono text-[11px] text-zinc-500">
                        {run.provider || 'provider'} · {run.model || 'model'} · {run.timestamp || ''}
                      </div>
                      <div className="whitespace-pre-wrap">{run.transcript}</div>
                    </div>
                  ))}
                </div>
              )}

              {sourceDetail.metaPath && (
                <div className="font-mono text-[11px] text-zinc-500">
                  Файл: {sourceDetail.metaPath}
                </div>
              )}
            </>
          ) : null}
        </div>
      </dialog>
    </div>
  );
}

function pathBasename(p: string): string {
  const parts = p.split('/');
  return parts[parts.length - 1] || p;
}

function ToolbarButton({
  pressed,
  expanded,
  onClick,
  label,
  title,
  badge = 0,
  children,
}: {
  pressed: boolean;
  /** Set for a button that opens a menu. */
  expanded?: boolean;
  onClick: () => void;
  label: string;
  title?: string;
  badge?: number;
  children: React.ReactNode;
}) {
  return (
    <button
      type="button"
      onClick={onClick}
      title={title ?? label}
      aria-label={label}
      {...(expanded === undefined ? { 'aria-pressed': pressed } : { 'aria-expanded': expanded })}
      className={`inline-flex shrink-0 items-center gap-1.5 rounded-md border px-2 py-1.5 text-xs font-medium transition ${
        pressed
          ? 'border-amber-500/50 bg-amber-500/15 text-amber-200'
          : 'border-zinc-800 bg-zinc-900 text-zinc-300 hover:border-zinc-700 hover:text-zinc-100'
      }`}
    >
      {children}
      <span className="hidden sm:inline">{label}</span>
      {badge > 0 && (
        <span className="rounded-full bg-amber-500/25 px-1.5 font-mono text-[10px] text-amber-200">{badge}</span>
      )}
    </button>
  );
}

const VIEW_TITLES: Record<View, string> = {
  feed: 'Лента',
  doc: 'Документ',
  dashboard: 'Дашборд',
  dialog: 'Диалог',
};

/** True from the width where the feed and the document sit side by side. */
function useIsWide(): boolean {
  const [wide, setWide] = useState(() => window.matchMedia('(min-width: 768px)').matches);
  useEffect(() => {
    const mq = window.matchMedia('(min-width: 768px)');
    const onChange = () => setWide(mq.matches);
    mq.addEventListener('change', onChange);
    return () => mq.removeEventListener('change', onChange);
  }, []);
  return wide;
}

function loadDocId(): string {
  try {
    return localStorage.getItem('wimm-web-doc-id') || 'main';
  } catch {
    return 'main';
  }
}

function saveDocId(id: string): void {
  try {
    localStorage.setItem('wimm-web-doc-id', id);
  } catch {
    // ignore
  }
}

// Per-viewer layout conveniences; the page works without storage.
function loadFlag(key: string, fallback: boolean): boolean {
  try {
    const v = localStorage.getItem(key);
    return v === null ? fallback : v === '1';
  } catch {
    return fallback;
  }
}

function saveFlag(key: string, value: boolean): void {
  try {
    localStorage.setItem(key, value ? '1' : '0');
  } catch {
    /* ignore */
  }
}
