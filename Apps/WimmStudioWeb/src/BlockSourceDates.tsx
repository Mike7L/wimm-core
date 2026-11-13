import { formatDay, formatDayRange } from './sourceDateFormat';
import type { SourceDateRange } from './types';

/** Under a paragraph: when its sources were captured. */
export function BlockSourceDates({ dates }: { dates: SourceDateRange }) {
  const many = dates.dated > 1;
  const notes = [
    dates.imported > 0 ? `из импорта: ${dates.imported}` : '',
    dates.undated > 0 ? `без даты: ${dates.undated}` : '',
  ].filter(Boolean);
  return (
    <p
      className="mt-1 text-[11px] leading-snug text-zinc-500 select-none"
      title={
        'Когда записаны источники этого абзаца (не когда абзац написан).' +
        (dates.imported > 0 ? ' У источников из массового импорта дата записи неизвестна.' : '')
      }
    >
      {dates.dated > 0 && (
        <>
          {many ? 'Источники' : 'Источник'}: {formatDayRange(dates.from, dates.to)}
          {many && ` · ${dates.dated}`}
          {notes.length > 0 && ' · '}
        </>
      )}
      {dates.dated === 0 && 'Дата записи неизвестна · '}
      {notes.join(' · ')}
    </p>
  );
}

/** Beside a heading: the newest source in the whole topic. */
export function SectionNewestSource({ dates }: { dates: SourceDateRange }) {
  if (dates.dated === 0) return null;
  return (
    <span
      className="ml-auto shrink-0 pl-3 text-[11px] font-normal whitespace-nowrap text-zinc-500"
      title={`Самый новый источник в теме. Все источники: ${formatDayRange(dates.from, dates.to)}`}
    >
      до {formatDay(dates.to)}
    </span>
  );
}
