/** Russian short dates for source date labels. Days are `YYYY-MM-DD`. */

const MONTHS = ['янв', 'фев', 'мар', 'апр', 'мая', 'июн', 'июл', 'авг', 'сен', 'окт', 'ноя', 'дек'];

function parts(day: string) {
  const [y, m, d] = day.split('-').map(Number);
  return { y, m, d };
}

export function formatDay(day: string): string {
  const { y, m, d } = parts(day);
  return `${d} ${MONTHS[m - 1]} ${y}`;
}

/** "3 ноя 2026", "5–10 ноя 2026", "5 мая – 10 ноя 2026", "3 дек 2015 – 10 ноя 2026". */
export function formatDayRange(from: string, to: string): string {
  if (from === to) return formatDay(to);
  const a = parts(from);
  const b = parts(to);
  if (a.y !== b.y) return `${formatDay(from)} – ${formatDay(to)}`;
  if (a.m !== b.m) return `${a.d} ${MONTHS[a.m - 1]} – ${formatDay(to)}`;
  return `${a.d}–${formatDay(to)}`;
}
