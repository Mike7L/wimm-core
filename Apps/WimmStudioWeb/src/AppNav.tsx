import type { LiveState } from './liveEvents';
import type { MouseEvent, ReactNode } from 'react';
import { BookOpenText, LayoutDashboard, MessagesSquare, Newspaper } from 'lucide-react';

/** The four screens. On a wide window the feed and the document share one screen. */
export type View = 'feed' | 'doc' | 'dashboard' | 'dialog';

export const VIEW_PATHS: Record<View, string> = {
  doc: '/',
  feed: '/feed',
  dashboard: '/dashboard',
  dialog: '/dialog',
};

export function viewFromPath(pathname: string): View {
  const p = pathname.replace(/\/+$/, '');
  if (p === '/feed') return 'feed';
  if (p === '/dashboard') return 'dashboard';
  if (p === '/dialog') return 'dialog';
  return 'doc';
}

interface AppNavProps {
  view: View;
  onNavigate: (view: View) => void;
  /** Questions and replies in the feed that wait for the owner: the number on the badge. */
  attention: number;
  /** Everything unread in the feed, changed paragraphs included: a dot when nothing waits. */
  unread: number;
  live: LiveState;
}

const LIVE_LABELS: Record<LiveState, string> = {
  live: 'на связи',
  offline: 'нет связи',
  elsewhere: 'в другой вкладке',
};
const LIVE_HINTS: Record<LiveState, string> = {
  live: 'Документ обновляется сам',
  offline: 'Нет связи с сервером — данные могут быть старыми',
  elsewhere: 'Wimm открыт в другой вкладке, эта не обновляется. Нажмите сюда — и обновляться будет она.',
};
const LIVE_DOTS: Record<LiveState, string> = {
  live: 'bg-emerald-400',
  offline: 'bg-zinc-600',
  elsewhere: 'bg-amber-400',
};

/** Left rail on a wide window, bottom tab bar on a phone. */
export function AppNav({ view, onNavigate, attention, unread, live }: AppNavProps) {
  const inWorkspace = view === 'feed' || view === 'doc';
  return (
    <nav
      aria-label="Разделы"
      className="order-last flex shrink-0 border-t border-zinc-800/80 bg-zinc-900/80 pb-[env(safe-area-inset-bottom)] md:order-first md:w-[76px] md:flex-col md:gap-1 md:border-t-0 md:border-r md:px-1.5 md:py-3 md:pb-3"
    >
      {/* Wide: one item for the shared feed + document screen. */}
      <NavItem
        className="hidden md:flex"
        view={inWorkspace ? view : 'doc'}
        active={inWorkspace}
        label="Лента и документ"
        shortLabel="Чтение"
        badge={attention}
        dot={unread > 0}
        onNavigate={onNavigate}
      >
        <BookOpenText className="h-5 w-5" aria-hidden="true" />
      </NavItem>
      {/* Phone: the feed and the document are separate tabs. */}
      <NavItem className="flex md:hidden" view="feed" active={view === 'feed'} label="Лента" badge={attention} dot={unread > 0} onNavigate={onNavigate}>
        <Newspaper className="h-5 w-5" aria-hidden="true" />
      </NavItem>
      <NavItem className="flex md:hidden" view="doc" active={view === 'doc'} label="Документ" onNavigate={onNavigate}>
        <BookOpenText className="h-5 w-5" aria-hidden="true" />
      </NavItem>
      <NavItem className="flex" view="dashboard" active={view === 'dashboard'} label="Дашборд" onNavigate={onNavigate}>
        <LayoutDashboard className="h-5 w-5" aria-hidden="true" />
      </NavItem>
      <NavItem className="flex" view="dialog" active={view === 'dialog'} label="Диалог" onNavigate={onNavigate}>
        <MessagesSquare className="h-5 w-5" aria-hidden="true" />
      </NavItem>

      <div
        className="mt-auto hidden flex-col items-center gap-1 pb-1 text-[10px] text-zinc-500 md:flex"
        title={LIVE_HINTS[live]}
      >
        <span className={`h-2 w-2 rounded-full ${LIVE_DOTS[live]}`} aria-hidden="true" />
        <span className="text-center leading-tight">{LIVE_LABELS[live]}</span>
      </div>
    </nav>
  );
}

function NavItem({
  view,
  active,
  label,
  shortLabel,
  badge = 0,
  dot = false,
  className,
  onNavigate,
  children,
}: {
  view: View;
  active: boolean;
  label: string;
  shortLabel?: string;
  badge?: number;
  dot?: boolean;
  className: string;
  onNavigate: (view: View) => void;
  children: ReactNode;
}) {
  const onClick = (e: MouseEvent) => {
    // Let ⌘-click and middle-click open a real tab.
    if (e.metaKey || e.ctrlKey || e.shiftKey || e.button !== 0) return;
    e.preventDefault();
    onNavigate(view);
  };
  return (
    <a
      href={VIEW_PATHS[view]}
      onClick={onClick}
      aria-current={active ? 'page' : undefined}
      aria-label={badge > 0 ? `${label}, ждут ответа: ${badge}` : dot ? `${label}, есть непрочитанное` : label}
      title={label}
      className={`${className} group min-w-0 flex-1 flex-col items-center justify-center gap-1 py-2 text-[10px] font-medium transition md:flex-none md:rounded-xl md:py-2 ${
        active ? 'text-amber-200' : 'text-zinc-400 hover:text-zinc-100'
      }`}
    >
      <span
        className={`relative flex h-8 w-12 items-center justify-center rounded-full transition ${
          active ? 'bg-amber-500/20' : 'group-hover:bg-zinc-800'
        }`}
      >
        {children}
        {badge > 0 && (
          <span className="absolute -top-1.5 -right-2 min-w-4 rounded-full bg-amber-400 px-1 text-center text-[10px] leading-4 font-bold text-zinc-950">
            {badge > 99 ? '99+' : badge}
          </span>
        )}
        {badge === 0 && dot && <span className="absolute top-0.5 right-2 h-2 w-2 rounded-full bg-amber-400" />}
      </span>
      <span className="max-w-full truncate px-0.5">{shortLabel ?? label}</span>
    </a>
  );
}
