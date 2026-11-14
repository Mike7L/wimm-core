import { liveSource } from '../liveEvents';
import { useCallback, useEffect, useMemo, useRef, useState, type CSSProperties, type ReactNode } from 'react';
import { ReplyActions, type ReplyMode } from './ReplyActions';
import { FeedNavigationContext, FeedText, SourceLinks, DocumentLink } from './FeedLinks';
import type { InboxChange, InboxPayload, InboxQuestion, InboxReply } from '../inboxTypes';
import { ReplySheet, type ReplyTarget } from './ReplySheet';
import { StoryView, type Story, type StoryItem } from './StoryView';
import {
  CheckAllIcon,
  CheckIcon,
  ChevronIcon,
  CloseIcon,
  HeartIcon,
  MicIcon,
  PaletteIcon,
  PlayIcon,
  passKindLabel,
  passSummary,
  plain,
  plural,
  relativeTime,
  shortDate,
  storyName,
} from './feedText';
import './tokens.css';
import './feed.css';

const THEMES = ['dark', 'light', 'ocean', 'sunset', 'forest', 'midnight', 'meadow', 'blossom'] as const;

type Filter = 'all' | 'questions' | 'replies' | 'changes';
const FILTERS: Filter[] = ['all', 'questions', 'replies', 'changes'];
const FILTER_LABEL: Record<Filter, string> = { all: 'Всё', questions: 'Вопросы', replies: 'Ответы', changes: 'Правки' };

/** Paragraphs shown in an open section before "ещё"; a section can hold hundreds. */
const SECTION_PAGE = 5;
const SECTION_MORE = 20;
/** Matches the collapse transition in feed.css. */
const LEAVE_MS = 360;

type Toast = { text: string; undo?: () => void };
type Section = { id: string; title: string; items: InboxChange[] };
type Reply = { target: ReplyTarget; onDone: (text: string) => Promise<void> };

function loadSetting<T extends string>(key: string, allowed: readonly T[], fallback: T): T {
  try {
    const v = localStorage.getItem(key) as T | null;
    return v && allowed.includes(v) ? v : fallback;
  } catch {
    return fallback;
  }
}

function saveSetting(key: string, value: string) {
  try {
    localStorage.setItem(key, value);
  } catch {
    // per-viewer convenience only
  }
}

async function postJson<T = any>(url: string, body: unknown): Promise<T> {
  const res = await fetch(url, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
  const data = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(data.error || `HTTP ${res.status}`);
  return data as T;
}

const clip = (text: string, n: number) => (text.length > n ? `${text.slice(0, n).replace(/\s+\S*$/, '')}…` : text);
const quoteOf = (c: InboxChange) => plain(c.text).slice(0, 280);
const whereOf = (...parts: (string | undefined)[]) => [...new Set(parts.filter(Boolean))].join(' · ');
const kindLabel = (kind: InboxChange['kind']) => (kind === 'added' ? 'Новое' : 'Изменено');
const toneOf = (kind: InboxChange['kind']) => (kind === 'added' ? 'var(--accent-green)' : 'var(--accent-orange)');
const sectionKey = (id: string) => `sec:${id}`;

export interface FeedAppProps {
  /** Shown as a column beside the document (or a phone tab) instead of a page of its own. */
  embedded?: boolean;
  /** "В документе" scrolls the reader to this block instead of navigating. */
  onOpenBlock?: (blockId: number) => void;
  onOpenSource?: (sourceId: string) => void;
  onNavigateAnchor?: (anchor: string) => void;
  onClose?: () => void;
  /** Reports what is unread: `attention` — questions and replies waiting for the owner, `total` — those plus changed paragraphs. */
  onUnreadChange?: (attention: number, total: number) => void;
}

export function FeedApp({ embedded = false, onOpenBlock, onOpenSource, onNavigateAnchor, onClose, onUnreadChange }: FeedAppProps = {}) {
  const [data, setData] = useState<InboxPayload | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [theme, setTheme] = useState(() => loadSetting('wimm-feed-theme', THEMES, 'dark'));
  const [filter, setFilter] = useState<Filter>(() => loadSetting('wimm-feed-filter', FILTERS, 'all'));
  const [readHashes, setReadHashes] = useState<Set<string>>(new Set());
  const [liked, setLiked] = useState<Map<number, string>>(new Map());
  const [answered, setAnswered] = useState<Map<number, string>>(new Map());
  const [later, setLater] = useState<Set<number>>(new Set());
  const [chaptersShown, setChaptersShown] = useState(1);
  const [closedThreads, setClosedThreads] = useState<Set<string>>(new Set());
  /** Keys of entries that are playing their exit; they are removed when it ends. */
  const [leaving, setLeaving] = useState<Set<string>>(new Set());
  const [openSections, setOpenSections] = useState<Set<string>>(new Set());
  const [sectionLimit, setSectionLimit] = useState<Record<string, number>>({});
  const [toast, setToast] = useState<Toast | null>(null);
  const [story, setStory] = useState<Story | null>(null);
  const [reply, setReply] = useState<Reply | null>(null);
  const rootRef = useRef<HTMLDivElement | null>(null);
  const loadId = useRef(0);
  const say = (text: string, undo?: () => void) => setToast({ text, undo });

  const load = useCallback(async () => {
    const id = ++loadId.current;
    try {
      const res = await fetch('/api/inbox', { cache: 'no-store' });
      const body = await res.json();
      if (!res.ok) throw new Error(body.error || `HTTP ${res.status}`);
      if (id !== loadId.current) return;
      setData(body as InboxPayload);
      setLiked(new Map((body as InboxPayload).liked.map((l) => [l.blockId, l.threadId])));
      setError(null);
    } catch (e: any) {
      if (id === loadId.current) setError(e?.message || 'Не удалось загрузить ленту');
    }
  }, []);

  useEffect(() => {
    void load();
    // The document or threads changed on disk (a secretary pass, Studio): reload.
    const es = liveSource('events');
    es.onmessage = (ev) => {
      try {
        // `connected` comes each time the stream opens: also when this tab wakes up.
        const type = JSON.parse(ev.data).type;
        if (type === 'reload' || type === 'connected') void load();
      } catch {
        // ignore
      }
    };
    return () => es.close();
  }, [load]);

  useEffect(() => {
    saveSetting('wimm-feed-theme', theme);
    const bg = getComputedStyle(document.querySelector('.wimm-feed') ?? document.body).getPropertyValue('--bg-primary');
    document.body.style.background = bg;
  }, [theme]);

  useEffect(() => {
    if (!toast) return;
    const id = window.setTimeout(() => setToast(null), toast.undo ? 7000 : 3500);
    return () => window.clearTimeout(id);
  }, [toast]);

  // ---- What is in the feed ----

  const changes = useMemo(() => (data?.changes ?? []).filter((c) => !readHashes.has(c.hash)), [data, readHashes]);
  const questions = useMemo(() => {
    const all = data?.questions ?? [];
    return [...all.filter((q) => !later.has(q.number)), ...all.filter((q) => later.has(q.number))];
  }, [data, later]);
  const openQuestions = questions.filter((q) => !answered.has(q.number));
  // Chapter questions come one chapter at a time: a chapter with unread edits first, then document order.
  const questionPages = useMemo(() => {
    const byTopic = new Map<string, InboxQuestion[]>();
    for (const q of questions) if (q.topic) byTopic.set(q.topic, [...(byTopic.get(q.topic) ?? []), q]);
    const chapters = [...byTopic].filter(([, items]) => items.length > 1);
    const paged = new Set(chapters.map(([topic]) => topic));
    const edited = (topic: string) => changes.some((c) => c.storyTitle.startsWith(topic));
    const first = (items: InboxQuestion[]) => Math.min(...items.map((q) => q.number));
    chapters.sort((a, b) => Number(edited(b[0])) - Number(edited(a[0])) || first(a[1]) - first(b[1]));
    return {
      loose: questions.filter((q) => !q.topic || !paged.has(q.topic)),
      chapters: chapters.map(([topic, items]) => ({ topic, items: [...items].sort((a, b) => a.number - b.number) })),
    };
  }, [questions, changes]);
  const shownChapters = questionPages.chapters.slice(0, chaptersShown);
  const nextChapter = questionPages.chapters[chaptersShown];
  const shownQuestions = [...questionPages.loose, ...shownChapters.flatMap((c) => c.items)];
  const replies = (data?.replies ?? []).filter((r) => !closedThreads.has(r.threadId));
  const attention = openQuestions.length + replies.length;
  const unread = attention + changes.length;

  useEffect(() => {
    if (data) onUnreadChange?.(attention, unread);
  }, [data, attention, unread, onUnreadChange]);

  /** Unread paragraphs under their level-2 heading. */
  const sections = useMemo<Section[]>(() => {
    const groups = new Map<string, Section>();
    for (const c of changes) {
      if (!groups.has(c.story)) groups.set(c.story, { id: c.story, title: c.storyTitle, items: [] });
      groups.get(c.story)!.items.push(c);
    }
    return [...groups.values()];
  }, [changes]);

  // A short feed needs no folding: with a handful of changes every section starts open.
  const fewChanges = changes.length <= 8;
  const isOpen = (id: string) => fewChanges || openSections.has(id);
  const toggleSection = (id: string) =>
    setOpenSections((set) => {
      const next = new Set(set);
      if (next.has(id)) next.delete(id);
      else next.add(id);
      return next;
    });

  const pickFilter = (f: Filter) => {
    setFilter(f);
    saveSetting('wimm-feed-filter', f);
    (embedded ? rootRef.current : document.scrollingElement)?.scrollTo({ top: 0 });
  };

  // ---- Leaving the feed, smoothly ----

  /** Plays the exit of these entries, then applies the change that removes them. */
  const dismiss = (keys: string[], commit: () => void) => {
    setLeaving((set) => new Set([...set, ...keys]));
    window.setTimeout(() => {
      commit();
      setLeaving((set) => {
        const next = new Set(set);
        for (const k of keys) next.delete(k);
        return next;
      });
    }, LEAVE_MS);
  };

  /** Marks paragraphs read: they fold away, and the toast offers to bring them back. */
  const markSeen = async (hashes: string[], done: string) => {
    if (!hashes.length) return;
    try {
      await postJson('/api/inbox/seen', { hashes });
    } catch (e: any) {
      say(`Отметка не сохранилась: ${e?.message ?? e}`);
      return;
    }
    const gone = new Set([...hashes, ...leaving]);
    // A section whose last paragraphs go folds as a whole, heading included.
    const emptied = sections.filter((sec) => sec.items.every((c) => gone.has(c.hash))).map((sec) => sectionKey(sec.id));
    dismiss([...hashes, ...emptied], () => setReadHashes((set) => new Set([...set, ...hashes])));
    say(done, () => {
      setToast(null);
      postJson('/api/inbox/unseen', { hashes })
        .then(() =>
          setReadHashes((set) => {
            const next = new Set(set);
            for (const h of hashes) next.delete(h);
            return next;
          })
        )
        .catch((e: any) => say(`Не получилось вернуть: ${e?.message ?? e}`));
    });
  };

  // ---- Actions ----

  const toggleLike = async (c: InboxChange) => {
    const thread = liked.get(c.blockId);
    try {
      if (thread) {
        await postJson('/api/threads', { action: 'status', threadId: thread, status: 'dropped' });
        setLiked((m) => {
          const next = new Map(m);
          next.delete(c.blockId);
          return next;
        });
      } else {
        const { record } = await postJson<{ record: { id: string } }>('/api/threads', {
          action: 'add',
          section: c.sectionId,
          heading: c.sectionHeading,
          quote: quoteOf(c),
          reaction: '👍',
          intent: 'agree',
        });
        setLiked((m) => new Map(m).set(c.blockId, record.id));
      }
    } catch (e: any) {
      say(`Не сохранилось: ${e?.message ?? e}`);
    }
  };

  const comment = (c: InboxChange, inputMode: ReplyMode = 'voice') =>
    setReply({
      target: {
        who: whereOf(c.storyTitle, c.heading),
        when: kindLabel(c.kind).toLowerCase(),
        prompt: clip(plain(c.text), 220),
        hint: 'Дополнение сохранится комментарием к абзацу — секретарь прочитает его в следующем проходе.',
        needsText: true,
        inputMode,
      },
      onDone: async (text) => {
        await postJson('/api/threads', { action: 'add', section: c.sectionId, heading: c.sectionHeading, quote: quoteOf(c), text });
        say('Комментарий сохранён');
      },
    });

  const answerQuestion = (q: InboxQuestion, inputMode: ReplyMode = 'voice') =>
    setReply({
      target: {
        who: 'Секретарь спрашивает',
        when: whereOf(`Q${q.number}`, q.storyTitle, q.heading),
        prompt: plain(q.text),
        hint: `Ответ сохранится заметкой «По Q${q.number} — …» и уйдёт секретарю со следующим проходом.`,
        needsText: true,
        inputMode,
      },
      onDone: async (text) => {
        const { noteText } = await postJson<{ noteText: string }>('/api/inbox/answer', { number: q.number, text });
        setAnswered((m) => new Map(m).set(q.number, noteText));
      },
    });

  const clarify = (r: InboxReply, inputMode: ReplyMode = 'voice') =>
    setReply({
      target: {
        who: 'Секретарь ответил на твой комментарий',
        when: r.heading,
        prompt: r.messages.at(-1)?.text ?? '',
        hint: 'Уточнение уйдёт ответом в эту ветку комментариев.',
        needsText: true,
        inputMode,
      },
      onDone: async (text) => {
        await postJson('/api/threads', { action: 'reply', threadId: r.threadId, text });
        dismiss([r.threadId], () => setClosedThreads((s) => new Set(s).add(r.threadId)));
        say('Уточнение отправлено в ветку');
      },
    });

  const closeThread = async (r: InboxReply) => {
    try {
      await postJson('/api/threads', { action: 'status', threadId: r.threadId, status: 'resolved' });
      dismiss([r.threadId], () => setClosedThreads((s) => new Set(s).add(r.threadId)));
      say('Ветка закрыта');
    } catch (e: any) {
      say(`Не закрылось: ${e?.message ?? e}`);
    }
  };

  const recordThought = () =>
    setReply({
      target: {
        who: 'Новая мысль',
        prompt: 'Что ты хочешь записать?',
        hint: 'Запись сохранится обычной голосовой заметкой; секретарь прочитает её в следующем проходе.',
        needsText: false,
      },
      onDone: async () => {},
    });

  // ---- Reading a section one paragraph at a time ----

  const openStory = (sec: Section) =>
    setStory({
      id: sec.id,
      name: sec.title,
      letter: storyName(sec.title).slice(0, 1).toUpperCase(),
      color: sec.items.some((c) => c.kind === 'edited') ? 'var(--accent-orange)' : 'var(--accent-green)',
      replyLabel: 'Дополнить голосом…',
      items: sec.items.map((c) => ({
        key: c.hash,
        text: c.text,
        previous: c.previous,
        meta: whereOf(c.heading, kindLabel(c.kind).toLowerCase()),
        sources: c.sources,
        blockId: c.blockId,
      })),
    });

  /** A story marks read only what was actually shown: closing halfway keeps the rest in the feed. */
  const finishStory = (s: Story, seenCount = s.items.length) => {
    setStory(null);
    const hashes = s.items.slice(0, seenCount).map((i) => i.key);
    void markSeen(hashes, hashes.length === s.items.length ? `Раздел «${storyName(s.name)}» прочитан` : `Прочитано: ${hashes.length} из ${s.items.length}`);
  };

  const replyFromStory = (item: StoryItem, mode: ReplyMode = 'voice') => {
    const c = data?.changes.find((x) => x.hash === item.key);
    if (c) comment(c, mode);
  };

  const readAll = async () => {
    if (!window.confirm('Отметить всё прочитанным? Следующие изменения будут считаться от текущего текста документа.')) return;
    try {
      await postJson('/api/inbox/read-all', {});
      await postJson('/api/inbox/replies-seen', {});
      await load();
      setReadHashes(new Set());
    } catch (e: any) {
      say(`Не получилось: ${e?.message ?? e}`);
    }
  };

  const cycleTheme = () => setTheme((t) => THEMES[(THEMES.indexOf(t) + 1) % THEMES.length]);

  // ---- Render ----

  const counts: Record<Filter, number> = { all: unread, questions: openQuestions.length, replies: replies.length, changes: changes.length };
  const active: Filter = filter !== 'all' && counts[filter] === 0 ? 'all' : filter;
  const shows = (f: Filter) => active === 'all' || active === f;
  const showsAttention = (shows('questions') && questions.length > 0) || (shows('replies') && replies.length > 0);
  const summary = !data
    ? ''
    : unread === 0
      ? 'Всё прочитано'
      : [
          attention > 0 ? `${attention} ${plural(attention, ['ждёт ответа', 'ждут ответа', 'ждут ответа'])}` : null,
          changes.length > 0 ? `${changes.length} ${plural(changes.length, ['правка', 'правки', 'правок'])} в ${sections.length} ${plural(sections.length, ['разделе', 'разделах', 'разделах'])}` : null,
        ]
          .filter(Boolean)
          .join(' · ');

  return (
    <FeedNavigationContext.Provider
      value={{
        onOpenBlock: onOpenBlock && ((id) => { setStory(null); onOpenBlock(id); }),
        onOpenSource: onOpenSource && ((id) => { setStory(null); onOpenSource(id); }),
        onNavigateAnchor: onNavigateAnchor && ((anchor) => { setStory(null); onNavigateAnchor(anchor); }),
      }}
    >
      <div ref={rootRef} className={embedded ? 'wimm-feed wimm-feed-panel' : 'wimm-feed'} data-theme={theme}>
        <div className="f-frame">
          <header className="f-head">
            <div className="f-title-row">
              <h1 className="f-title">Лента</h1>
              {data && unread > 0 && (
                <button type="button" className="act" onClick={readAll} aria-label="Отметить всё прочитанным" title="Отметить всё прочитанным">
                  <CheckAllIcon size={20} />
                </button>
              )}
              <button type="button" className="act" onClick={cycleTheme} aria-label={`Тема: ${theme}. Сменить`} title={`Тема: ${theme}`}>
                <PaletteIcon size={18} />
              </button>
              <button type="button" className="act f-mic" onClick={recordThought} aria-label="Записать мысль" title="Записать мысль">
                <MicIcon size={18} />
              </button>
              {onClose && (
                <button type="button" className="act" onClick={onClose} aria-label="Свернуть ленту" title="Свернуть ленту">
                  <CloseIcon size={18} />
                </button>
              )}
            </div>
            <div className="f-sub" aria-live="polite">{summary}</div>
            {data && unread > 0 && (
              <div className="f-tabs" role="tablist" aria-label="Что показывать">
                {FILTERS.filter((f) => f === 'all' || counts[f] > 0).map((f) => (
                  <button key={f} type="button" role="tab" aria-selected={active === f} className="f-tab" onClick={() => pickFilter(f)}>
                    {FILTER_LABEL[f]}
                    <span className="f-n">{counts[f]}</span>
                  </button>
                ))}
              </div>
            )}
          </header>

          <main className="f-main">
            {error && (
              <div role="alert" className="f-entry" style={{ '--tone': 'var(--accent-orange)' } as CSSProperties}>
                <p className="f-text">{error}</p>
                <div className="f-actions">
                  <button type="button" className="chip" onClick={() => void load()}>
                    Повторить
                  </button>
                </div>
              </div>
            )}
            {!data && !error && <Skeleton />}

            {data && (
              <div className="f-list" key={active}>
                {showsAttention && <GroupLabel>Ждут тебя</GroupLabel>}
                {shows('questions') &&
                  shownQuestions.map((q) => (
                    <Fx key={`q${q.number}`} leaving={false}>
                      <QuestionEntry q={q} answeredNote={answered.get(q.number)} deferred={later.has(q.number)} onAnswer={(mode) => answerQuestion(q, mode)} onLater={() => setLater((s) => new Set(s).add(q.number))} />
                    </Fx>
                  ))}
                {shows('questions') && nextChapter && (
                  <button type="button" className="chip f-more" onClick={() => setChaptersShown((n) => n + 1)}>
                    Ещё вопросы: «{nextChapter.topic}» · {nextChapter.items.length}
                    {questionPages.chapters.length - chaptersShown > 1 && `, всего глав ${questionPages.chapters.length - chaptersShown}`}
                  </button>
                )}
                {shows('replies') &&
                  replies.map((r) => (
                    <Fx key={r.threadId} leaving={leaving.has(r.threadId)}>
                      <ReplyEntry r={r} onClose={() => void closeThread(r)} onClarify={(mode) => clarify(r, mode)} />
                    </Fx>
                  ))}

                {shows('changes') && sections.length > 0 && (
                  <GroupLabel>
                    Правки по разделам
                    {data.baseline && <span className="f-label-note"> · с {shortDate(data.baseline.date)}</span>}
                  </GroupLabel>
                )}
                {shows('changes') &&
                  sections.map((sec) => {
                    const open = isOpen(sec.id);
                    const limit = sectionLimit[sec.id] ?? SECTION_PAGE;
                    const rest = sec.items.length - limit;
                    const edited = sec.items.filter((c) => c.kind === 'edited').length;
                    return (
                      <Fx key={sec.id} leaving={leaving.has(sectionKey(sec.id))}>
                        <section aria-label={`Правки раздела: ${sec.title}`} className="f-sec">
                          <button type="button" className="f-sec-row" aria-expanded={open} onClick={() => toggleSection(sec.id)} disabled={fewChanges}>
                            <span className="f-sec-mark" style={{ '--tone': edited > 0 ? 'var(--accent-orange)' : 'var(--accent-green)' } as CSSProperties}>
                              {storyName(sec.title).slice(0, 1).toUpperCase()}
                            </span>
                            <span className="f-sec-main">
                              <span className="f-sec-title">{sec.title}</span>
                              <span className="f-sec-preview">{open ? sectionStats(sec.items.length - edited, edited) : clip(plain(sec.items[0].text), 90)}</span>
                            </span>
                            <span className="f-n">{sec.items.length}</span>
                            {!fewChanges && <ChevronIcon size={16} style={{ transform: open ? 'rotate(90deg)' : undefined, transition: 'transform 0.25s ease', color: 'var(--text-tertiary)' }} />}
                          </button>
                          <Fold open={open}>
                            <div className="f-sec-tools">
                              <button type="button" className="chip small" onClick={() => openStory(sec)} title="Показать раздел по одному абзацу">
                                <PlayIcon size={13} />
                                Читать подряд
                              </button>
                              <button type="button" className="chip small" onClick={() => void markSeen(sec.items.map((c) => c.hash), `Раздел «${storyName(sec.title)}» прочитан`)}>
                                <CheckIcon size={14} />
                                Раздел прочитан
                              </button>
                            </div>
                            {sec.items.slice(0, limit).map((c) => (
                              <Fx key={c.hash + c.blockId} leaving={leaving.has(c.hash)}>
                                <ChangeEntry c={c} liked={liked.has(c.blockId)} onLike={() => void toggleLike(c)} onReply={(mode) => comment(c, mode)} onSeen={() => void markSeen([c.hash], 'Отмечено прочитанным')} />
                              </Fx>
                            ))}
                            {rest > 0 && (
                              <button type="button" className="chip f-more" onClick={() => setSectionLimit((m) => ({ ...m, [sec.id]: limit + SECTION_MORE }))}>
                                Ещё {Math.min(rest, SECTION_MORE)} из {rest}
                              </button>
                            )}
                          </Fold>
                        </section>
                      </Fx>
                    );
                  })}

                {unread === 0 && <AllRead />}
                {active === 'all' && data.passes.length > 0 && <PassLog passes={data.passes} />}
              </div>
            )}
          </main>

          {toast && (
            <div role="status" className="f-toast">
              <span>{toast.text}</span>
              {toast.undo && (
                <button type="button" onClick={toast.undo}>
                  Вернуть
                </button>
              )}
            </div>
          )}
        </div>

        {story && <StoryView story={story} onFinish={() => finishStory(story)} onClose={(seenCount) => finishStory(story, seenCount)} onReply={(item, mode) => replyFromStory(item, mode)} />}
        {reply && <ReplySheet target={reply.target} onDone={reply.onDone} onClose={() => setReply(null)} />}
      </div>
    </FeedNavigationContext.Provider>
  );
}

// ---- Motion ----

/** One feed entry: fades in when it appears and folds to nothing while `leaving`. */
function Fx({ leaving, children }: { leaving: boolean; children: ReactNode }) {
  return (
    <div className={leaving ? 'fx leaving' : 'fx'} aria-hidden={leaving || undefined}>
      <div className="fx-body">{children}</div>
    </div>
  );
}

/** A section's body: unfolds and folds; its content is built on first opening and then kept. */
function Fold({ open, children }: { open: boolean; children: ReactNode }) {
  const [built, setBuilt] = useState(open);
  const [shown, setShown] = useState(open);
  useEffect(() => {
    if (!open) {
      setShown(false);
      return;
    }
    setBuilt(true);
    // A beat closed with the content in place, so the unfold has a height to grow to.
    // A timer, not requestAnimationFrame: frames stop in a background tab and the section would stay shut.
    const id = window.setTimeout(() => setShown(true), 20);
    return () => window.clearTimeout(id);
  }, [open]);
  return (
    <div className={shown ? 'fold open' : 'fold'}>
      <div className="fold-body" inert={!open}>
        {built && children}
      </div>
    </div>
  );
}

// ---- Entries ----

function GroupLabel({ children }: { children: ReactNode }) {
  return <h2 className="f-label">{children}</h2>;
}

function EntryMeta({ kind, where, blockId }: { kind: string; where?: string; blockId?: number }) {
  return (
    <div className="f-meta">
      <span className="f-kind">{kind}</span>
      <span className="f-where" title={where}>{where}</span>
      <DocumentLink blockId={blockId} />
    </div>
  );
}

function ChangeEntry({ c, liked, onLike, onReply, onSeen }: { c: InboxChange; liked: boolean; onLike: () => void; onReply: (mode: ReplyMode) => void; onSeen: () => void }) {
  const [old, setOld] = useState(false);
  const [expanded, setExpanded] = useState(false);
  const markdown = old && c.previous ? c.previous : c.text;
  const long = plain(markdown).length > 420;
  return (
    <article className="f-entry" style={{ '--tone': toneOf(c.kind) } as CSSProperties}>
      <EntryMeta kind={kindLabel(c.kind)} where={c.heading && c.heading !== c.storyTitle ? c.heading : undefined} blockId={c.blockId} />
      {c.previous && (
        <div className="f-versions" role="tablist" aria-label="Версия">
          <button type="button" role="tab" aria-selected={!old} className="seg" onClick={() => setOld(false)}>
            Стало
          </button>
          <button type="button" role="tab" aria-selected={old} className="seg" onClick={() => setOld(true)}>
            Было
          </button>
        </div>
      )}
      <p className={`f-text${long && !expanded ? ' clamp' : ''}${old ? ' old' : ''}`}>
        <FeedText text={markdown} />
      </p>
      {long && (
        <button type="button" className="f-link" onClick={() => setExpanded((v) => !v)}>
          {expanded ? 'Свернуть' : 'Читать целиком'}
        </button>
      )}
      <SourceLinks sources={c.sources} />
      <div className="f-actions">
        <button type="button" className="chip" onClick={onSeen} title="Прочитано — убрать из ленты">
          <CheckIcon size={15} />
          Прочитано
        </button>
        <button type="button" className="chip round f-heart" onClick={onLike} aria-label={liked ? 'Убрать «согласен»' : 'Согласен'} title={liked ? 'Убрать «согласен»' : 'Согласен'} aria-pressed={liked}>
          <HeartIcon size={16} filled={liked} />
        </button>
        <span className="f-space" />
        <ReplyActions onReply={onReply} voiceLabel="Дополнить голосом" compact />
      </div>
    </article>
  );
}

function QuestionEntry({ q, answeredNote, deferred, onAnswer, onLater }: { q: InboxQuestion; answeredNote?: string; deferred: boolean; onAnswer: (mode: ReplyMode) => void; onLater: () => void }) {
  return (
    <article className="f-entry attn" style={{ '--tone': 'var(--accent-blue)', opacity: deferred && !answeredNote ? 0.6 : undefined } as CSSProperties}>
      <EntryMeta kind={`Вопрос Q${q.number}`} where={whereOf(q.storyTitle ?? q.topic, q.heading)} blockId={q.blockId} />
      <p className="f-text lead">
        <FeedText text={q.topic && q.text.startsWith(`${q.topic}. `) ? q.text.slice(q.topic.length + 2) : q.text} />
      </p>
      <SourceLinks sources={q.sourceInfo} />
      {answeredNote ? (
        <div className="f-done">
          <CheckIcon size={16} />
          <span>
            Ответ сохранён заметкой «{clip(answeredNote, 90)}». Секретарь учтёт его в следующем проходе.
          </span>
        </div>
      ) : (
        <div className="f-actions">
          <ReplyActions onReply={onAnswer} voiceLabel="Ответить" />
          <span className="f-space" />
          {!deferred && (
            <button type="button" className="chip quiet" onClick={onLater}>
              Позже
            </button>
          )}
        </div>
      )}
    </article>
  );
}

function ReplyEntry({ r, onClose, onClarify }: { r: InboxReply; onClose: () => void; onClarify: (mode: ReplyMode) => void }) {
  return (
    <article className="f-entry attn" style={{ '--tone': 'var(--accent-purple)' } as CSSProperties}>
      <EntryMeta kind="Ответ секретаря" where={whereOf(r.heading, relativeTime(r.at))} blockId={r.blockId ?? undefined} />
      {r.quote && (
        <blockquote className="f-quote">
          <FeedText text={r.quote} />
        </blockquote>
      )}
      <div className="f-thread">
        {r.messages.map((m, i) => {
          const mine = m.author === 'owner';
          return (
            <div key={i} className={mine ? 'f-msg mine' : 'f-msg'}>
              <span className="f-msg-who">{mine ? 'Ты' : 'Секретарь'}</span>
              <span className="f-msg-text">
                <FeedText text={m.text} />
              </span>
            </div>
          );
        })}
      </div>
      <div className="f-actions">
        <button type="button" className="chip" onClick={onClose} title="Ответ верный — закрыть ветку">
          <CheckIcon size={15} />
          Верно
        </button>
        <span className="f-space" />
        <ReplyActions onReply={onClarify} voiceLabel="Уточнить" />
      </div>
    </article>
  );
}

function sectionStats(added: number, edited: number): string {
  return [
    added > 0 ? `${added} ${plural(added, ['новый абзац', 'новых абзаца', 'новых абзацев'])}` : null,
    edited > 0 ? `${edited} ${plural(edited, ['изменён', 'изменено', 'изменено'])}` : null,
  ]
    .filter(Boolean)
    .join(' · ');
}

function PassLog({ passes }: { passes: InboxPayload['passes'] }) {
  const [open, setOpen] = useState(false);
  const shown = open ? passes : passes.slice(0, 1);
  return (
    <section aria-label="Журнал проходов" className="f-log">
      <div className="f-log-head">
        <span>Журнал секретаря</span>
        {passes.length > 1 && (
          <button type="button" className="f-link" onClick={() => setOpen((v) => !v)}>
            {open ? 'Свернуть' : `Все проходы · ${passes.length}`}
          </button>
        )}
      </div>
      {shown.map((p, i) => {
        const { kind, text } = passSummary(p);
        return (
          <div key={p.date + i} className="f-log-row">
            <div className="f-log-when">
              {passKindLabel(kind)} · {shortDate(p.date.replace(' ', 'T'))} {p.date.slice(11, 16)}
            </div>
            <div className={open ? 'f-log-text' : 'f-log-text clamp'}>{text}</div>
          </div>
        );
      })}
    </section>
  );
}

function AllRead() {
  return (
    <div className="f-empty">
      <span className="f-empty-mark">
        <CheckIcon size={26} />
      </span>
      <div className="f-empty-title">Ты всё прочитал</div>
      <div className="f-empty-text">Новое появится после следующего прохода секретаря.</div>
    </div>
  );
}

function Skeleton() {
  return (
    <div className="f-list" aria-label="Собираем, что нового…" aria-busy="true">
      {[72, 110, 88].map((h, i) => (
        <div key={i} className="f-skeleton" style={{ height: h }} />
      ))}
    </div>
  );
}
