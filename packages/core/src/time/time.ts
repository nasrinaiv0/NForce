/**
 * Time utilities.
 *
 * Rules: store and compare instants in UTC (ISO-8601); derive local calendar
 * dates only through an explicit IANA time zone (the organization or site
 * zone), never through the device's zone. A "date key" is a `YYYY-MM-DD`
 * calendar date with no time zone attached.
 */

export type DateKey = `${number}-${number}-${number}`;

const MS_PER_MINUTE = 60_000;
const MS_PER_DAY = 86_400_000;
const DATE_KEY_RE = /^(\d{4})-(\d{2})-(\d{2})$/;

const formatterCache = new Map<string, Intl.DateTimeFormat>();

function partsFormatter(timeZone: string): Intl.DateTimeFormat {
  let f = formatterCache.get(timeZone);
  if (f === undefined) {
    f = new Intl.DateTimeFormat('en-US', {
      timeZone,
      hourCycle: 'h23',
      year: 'numeric',
      month: '2-digit',
      day: '2-digit',
      hour: '2-digit',
      minute: '2-digit',
    });
    formatterCache.set(timeZone, f);
  }
  return f;
}

export interface ZonedParts {
  readonly year: number;
  readonly month: number; // 1-12
  readonly day: number; // 1-31
  readonly hour: number; // 0-23
  readonly minute: number;
}

/** Wall-clock parts of `instant` in `timeZone`. */
export function zonedParts(instant: Date, timeZone: string): ZonedParts {
  const out: Record<string, number> = {};
  for (const p of partsFormatter(timeZone).formatToParts(instant)) {
    if (p.type !== 'literal') out[p.type] = Number(p.value);
  }
  return {
    year: out['year'] ?? 0,
    month: out['month'] ?? 0,
    day: out['day'] ?? 0,
    hour: (out['hour'] ?? 0) % 24,
    minute: out['minute'] ?? 0,
  };
}

const pad = (n: number, width = 2) => String(n).padStart(width, '0');

export const toDateKey = (year: number, month: number, day: number): DateKey =>
  `${pad(year, 4)}-${pad(month)}-${pad(day)}` as DateKey;

/** Calendar date of `instant` in `timeZone`. */
export function localDateKey(instant: Date, timeZone: string): DateKey {
  const { year, month, day } = zonedParts(instant, timeZone);
  return toDateKey(year, month, day);
}

export function parseDateKey(key: string): { year: number; month: number; day: number } {
  const m = DATE_KEY_RE.exec(key);
  if (m === null) throw new RangeError(`Invalid date key: ${key}`);
  const year = Number(m[1]);
  const month = Number(m[2]);
  const day = Number(m[3]);
  const probe = new Date(Date.UTC(year, month - 1, day));
  if (probe.getUTCFullYear() !== year || probe.getUTCMonth() !== month - 1 || probe.getUTCDate() !== day) {
    throw new RangeError(`Invalid calendar date: ${key}`);
  }
  return { year, month, day };
}

export const isDateKey = (value: string): value is DateKey => {
  try {
    parseDateKey(value);
    return true;
  } catch {
    return false;
  }
};

const keyToUtcMs = (key: string): number => {
  const { year, month, day } = parseDateKey(key);
  return Date.UTC(year, month - 1, day);
};

export function addDays(key: DateKey, days: number): DateKey {
  const d = new Date(keyToUtcMs(key) + days * MS_PER_DAY);
  return toDateKey(d.getUTCFullYear(), d.getUTCMonth() + 1, d.getUTCDate());
}

/** Whole days from `a` to `b` (positive when `b` is later). */
export const daysBetween = (a: DateKey, b: DateKey): number => Math.round((keyToUtcMs(b) - keyToUtcMs(a)) / MS_PER_DAY);

/** ISO weekday: 1 = Monday … 7 = Sunday. */
export function isoWeekday(key: DateKey): number {
  const dow = new Date(keyToUtcMs(key)).getUTCDay();
  return dow === 0 ? 7 : dow;
}

/** Inclusive list of date keys from `start` to `end`. Empty if `end < start`. */
export function dateRange(start: DateKey, end: DateKey): DateKey[] {
  const n = daysBetween(start, end);
  return Array.from({ length: Math.max(0, n + 1) }, (_, i) => addDays(start, i));
}

export const minutesBetween = (startIso: string, endIso: string): number =>
  Math.floor((Date.parse(endIso) - Date.parse(startIso)) / MS_PER_MINUTE);

/** Compact, locale-neutral duration like `7h 05m` or `45m`. */
export function formatDuration(totalMinutes: number): string {
  const sign = totalMinutes < 0 ? '-' : '';
  const m = Math.abs(Math.trunc(totalMinutes));
  const h = Math.floor(m / 60);
  const rest = m % 60;
  return h === 0 ? `${sign}${rest}m` : `${sign}${h}h ${pad(rest)}m`;
}

/** Stopwatch format `HH:MM:SS` for live timers. */
export function formatClock(totalSeconds: number): string {
  const s = Math.max(0, Math.floor(totalSeconds));
  return `${pad(Math.floor(s / 3600))}:${pad(Math.floor((s % 3600) / 60))}:${pad(s % 60)}`;
}

/**
 * Instant for a wall-clock time on `date` in `timeZone`.
 * Resolves DST gaps forward and DST overlaps to the earlier instant.
 */
export function instantFromZoned(date: DateKey, hour: number, minute: number, timeZone: string): Date {
  const { year, month, day } = parseDateKey(date);
  const target = Date.UTC(year, month - 1, day, hour, minute);
  let guess = target;
  for (let i = 0; i < 3; i++) {
    const p = zonedParts(new Date(guess), timeZone);
    const seen = Date.UTC(p.year, p.month - 1, p.day, p.hour, p.minute);
    const diff = target - seen;
    if (diff === 0) break;
    guess += diff;
  }
  return new Date(guess);
}
