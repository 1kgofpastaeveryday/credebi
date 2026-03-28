/**
 * JST date utilities for Credebi.
 *
 * All date-boundary logic in this app uses Asia/Tokyo explicitly.
 * Do NOT use new Date().toISOString() for date boundaries — it produces UTC.
 * Use these helpers instead.
 *
 * See CLAUDE.md: "Timezone: All date-boundary logic must use Asia/Tokyo explicitly"
 */

/** Returns today's date in JST as 'YYYY-MM-DD' string. */
export function todayJST(): string {
  return new Date().toLocaleDateString('sv-SE', { timeZone: 'Asia/Tokyo' });
}

/** Returns current time interpreted as JST Date object. */
export function nowJST(): Date {
  return new Date(
    new Date().toLocaleString('en-US', { timeZone: 'Asia/Tokyo' })
  );
}

/** Adds days to a YYYY-MM-DD date string, returns YYYY-MM-DD. */
export function addDaysJST(dateStr: string, days: number): string {
  const d = new Date(dateStr + 'T00:00:00+09:00');
  d.setDate(d.getDate() + days);
  return d.toLocaleDateString('sv-SE', { timeZone: 'Asia/Tokyo' });
}

/**
 * Returns the first day of the given month in JST.
 * month is 1-indexed (1=Jan, 12=Dec).
 */
export function firstOfMonthJST(year: number, month: number): string {
  return `${year}-${String(month).padStart(2, '0')}-01`;
}
