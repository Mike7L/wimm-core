import type { DocumentBlock, SourceDateRange } from '../src/types';

/**
 * Dates of a block are computed from the sources it cites, never written into the document.
 * The date is when a source was captured (or when the owner said it), not when the paragraph
 * was written: a paragraph written today from a July note is a July paragraph.
 */
export type SourceDateLookup = (sourceId: string) => string | undefined;

const DAY = /^\d{4}-\d{2}-\d{2}/;

/**
 * A day on which this many sources entered the library is a bulk import (voice memos, bank
 * statements, chat photos), and its date is the import's, not the recording's. Measured
 * 2026-11-11: four such days hold 309–749 sources each, the busiest real day holds 106.
 */
export const BULK_IMPORT_DAY_SOURCES = 200;

export function bulkImportDays(recordedAt: Iterable<string | undefined>): Set<string> {
  const perDay = new Map<string, number>();
  for (const at of recordedAt) {
    const day = DAY.exec(at ?? '')?.[0];
    if (day) perDay.set(day, (perDay.get(day) ?? 0) + 1);
  }
  const days = new Set<string>();
  for (const [day, count] of perDay) if (count >= BULK_IMPORT_DAY_SOURCES) days.add(day);
  return days;
}

function rangeOf(
  ids: Iterable<string>,
  dateOf: SourceDateLookup,
  importDays: ReadonlySet<string>
): SourceDateRange | undefined {
  let from = '';
  let to = '';
  let dated = 0;
  let undated = 0;
  let imported = 0;
  for (const id of ids) {
    const day = DAY.exec(dateOf(id) ?? '')?.[0];
    if (!day) {
      undated += 1;
      continue;
    }
    if (importDays.has(day)) {
      imported += 1;
      continue;
    }
    dated += 1;
    if (!from || day < from) from = day;
    if (!to || day > to) to = day;
  }
  return dated + imported > 0 ? { from, to, dated, undated, imported } : undefined;
}

/**
 * A paragraph gets the range of its own sources. A heading of level 2+ gets the range of every
 * paragraph below it up to the next heading of the same or a higher level. Sources from a bulk
 * import day are counted apart and stay out of the range.
 */
export function attachSourceDates(
  blocks: DocumentBlock[],
  dateOf: SourceDateLookup,
  importDays: ReadonlySet<string> = new Set()
): void {
  const open: Array<{ block: DocumentBlock; level: number; ids: Set<string> }> = [];
  const close = (downTo: number) => {
    while (open.length > 0 && open[open.length - 1].level >= downTo) {
      const section = open.pop()!;
      const range = rangeOf(section.ids, dateOf, importDays);
      if (range) section.block.sourceDates = range;
    }
  };

  for (const block of blocks) {
    if (block.kind.type === 'heading') {
      close(block.kind.level);
      if (block.kind.level >= 2) open.push({ block, level: block.kind.level, ids: new Set() });
      continue;
    }
    if (block.kind.type !== 'body' || block.sources.length === 0) continue;
    const range = rangeOf(block.sources, dateOf, importDays);
    if (range) block.sourceDates = range;
    for (const section of open) for (const id of block.sources) section.ids.add(id);
  }
  close(0);
}
