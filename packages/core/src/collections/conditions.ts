import { foldText, type SortAccessors, type SortValue } from './query';

/**
 * Custom filtering: people build their own conditions ("Overtime > 2 h",
 * "Status is any of Pending, Returned", "Start date on or after Dec 1") on any
 * field a list exposes, and match all or any of them. Pure and shared by every
 * list, table and client.
 *
 * Incomplete conditions (no value yet) are ignored rather than hiding
 * everything, so a half-built filter never empties the list.
 */
export type FieldKind = 'text' | 'number' | 'duration' | 'percent' | 'date' | 'choice' | 'boolean';

export type FieldValue = string | number | boolean | null | undefined | readonly string[];

export interface FieldOption {
  readonly value: string;
  readonly label: string;
}

export interface FieldDef<T> {
  readonly key: string;
  readonly label: string;
  readonly kind: FieldKind;
  /**
   * The value to filter and sort on. Dates are `YYYY-MM-DD` or ISO instants,
   * durations are minutes, percents are 0–1 ratios, choices may be multi-valued.
   */
  readonly get: (item: T) => FieldValue;
  /** Choices to pick from (required for `choice`). */
  readonly options?: readonly FieldOption[];
  /** Set false for fields that only make sense as filters. */
  readonly sortable?: boolean;
}

export type Operator =
  | 'contains'
  | 'not_contains'
  | 'is'
  | 'is_not'
  | 'starts_with'
  | 'any_of'
  | 'none_of'
  | 'eq'
  | 'neq'
  | 'gt'
  | 'gte'
  | 'lt'
  | 'lte'
  | 'between'
  | 'on'
  | 'before'
  | 'after'
  | 'on_or_before'
  | 'on_or_after'
  | 'is_true'
  | 'is_false'
  | 'is_empty'
  | 'not_empty';

export const OPERATORS: Readonly<Record<FieldKind, readonly Operator[]>> = {
  text: ['contains', 'not_contains', 'is', 'is_not', 'starts_with', 'is_empty', 'not_empty'],
  number: ['eq', 'neq', 'gt', 'gte', 'lt', 'lte', 'between', 'is_empty', 'not_empty'],
  duration: ['gt', 'gte', 'lt', 'lte', 'eq', 'neq', 'between'],
  percent: ['gte', 'lte', 'gt', 'lt', 'between'],
  date: ['on', 'before', 'after', 'on_or_before', 'on_or_after', 'between', 'is_empty', 'not_empty'],
  choice: ['any_of', 'none_of', 'is_empty', 'not_empty'],
  boolean: ['is_true', 'is_false'],
};

/** Operators that need no value. */
export const VALUELESS: ReadonlySet<Operator> = new Set<Operator>(['is_true', 'is_false', 'is_empty', 'not_empty']);

export interface Condition {
  readonly id: string;
  readonly field: string;
  readonly op: Operator;
  /** Text, number (durations in minutes, percents as 0–1), date key, or chosen options. */
  readonly value?: string | number | readonly string[];
  /** Upper bound for `between`. */
  readonly value2?: string | number;
}

export type MatchMode = 'all' | 'any';

const isMissing = (v: FieldValue) => v === undefined || v === null || v === '' || (Array.isArray(v) && v.length === 0);
const asNumber = (v: unknown): number | undefined => (typeof v === 'number' && Number.isFinite(v) ? v : typeof v === 'string' && v.trim() !== '' && Number.isFinite(Number(v)) ? Number(v) : undefined);
const dateKeyOf = (v: unknown): string | undefined => (typeof v === 'string' && /^\d{4}-\d{2}-\d{2}/.test(v) ? v.slice(0, 10) : undefined);
const listOf = (v: FieldValue): string[] => (Array.isArray(v) ? [...v] : isMissing(v) ? [] : [String(v)]);

/** Is the condition complete enough to apply? */
export function isComplete(field: FieldDef<unknown> | undefined, c: Condition): boolean {
  if (field === undefined || !OPERATORS[field.kind].includes(c.op)) return false;
  if (VALUELESS.has(c.op)) return true;
  switch (field.kind) {
    case 'text':
      return typeof c.value === 'string' && c.value.trim().length > 0;
    case 'choice':
      return Array.isArray(c.value) && c.value.length > 0;
    case 'date':
      return dateKeyOf(c.value) !== undefined && (c.op !== 'between' || dateKeyOf(c.value2) !== undefined);
    default:
      return asNumber(c.value) !== undefined && (c.op !== 'between' || asNumber(c.value2) !== undefined);
  }
}

/** Does one item satisfy one (complete) condition? */
export function matches<T>(item: T, field: FieldDef<T>, c: Condition): boolean {
  const raw = field.get(item);
  if (c.op === 'is_empty') return isMissing(raw);
  if (c.op === 'not_empty') return !isMissing(raw);
  if (c.op === 'is_true') return raw === true;
  if (c.op === 'is_false') return raw !== true;

  switch (field.kind) {
    case 'text': {
      const hay = listOf(raw).map(foldText);
      const needle = foldText(String(c.value ?? '').trim());
      switch (c.op) {
        case 'contains':
          return hay.some((h) => h.includes(needle));
        case 'not_contains':
          return hay.every((h) => !h.includes(needle));
        case 'is':
          return hay.some((h) => h === needle);
        case 'is_not':
          return hay.every((h) => h !== needle);
        case 'starts_with':
          return hay.some((h) => h.startsWith(needle));
        default:
          return true;
      }
    }
    case 'choice': {
      const have = listOf(raw);
      const wanted = Array.isArray(c.value) ? (c.value as readonly string[]) : [];
      return c.op === 'none_of' ? have.every((h) => !wanted.includes(h)) : have.some((h) => wanted.includes(h));
    }
    case 'date': {
      const d = dateKeyOf(raw);
      const a = dateKeyOf(c.value) ?? '';
      if (d === undefined) return false;
      switch (c.op) {
        case 'on':
          return d === a;
        case 'before':
          return d < a;
        case 'after':
          return d > a;
        case 'on_or_before':
          return d <= a;
        case 'on_or_after':
          return d >= a;
        case 'between': {
          const b = dateKeyOf(c.value2) ?? '';
          const [lo, hi] = a <= b ? [a, b] : [b, a];
          return d >= lo && d <= hi;
        }
        default:
          return true;
      }
    }
    default: {
      const n = asNumber(raw);
      const a = asNumber(c.value) ?? 0;
      if (n === undefined) return false;
      switch (c.op) {
        case 'eq':
          return n === a;
        case 'neq':
          return n !== a;
        case 'gt':
          return n > a;
        case 'gte':
          return n >= a;
        case 'lt':
          return n < a;
        case 'lte':
          return n <= a;
        case 'between': {
          const b = asNumber(c.value2) ?? a;
          const [lo, hi] = a <= b ? [a, b] : [b, a];
          return n >= lo && n <= hi;
        }
        default:
          return true;
      }
    }
  }
}

/** Apply the complete conditions (all or any). Never mutates the input. */
export function applyConditions<T>(items: readonly T[], fields: readonly FieldDef<T>[], conditions: readonly Condition[], match: MatchMode = 'all'): T[] {
  const byKey = new Map(fields.map((f) => [f.key, f]));
  const active = conditions.flatMap((c) => {
    const field = byKey.get(c.field);
    return field !== undefined && isComplete(field as FieldDef<unknown>, c) ? [{ c, field }] : [];
  });
  if (active.length === 0) return [...items];
  return items.filter((item) => (match === 'all' ? active.every(({ c, field }) => matches(item, field, c)) : active.some(({ c, field }) => matches(item, field, c))));
}

/** How many conditions currently apply. */
export const activeConditionCount = <T>(fields: readonly FieldDef<T>[], conditions: readonly Condition[]): number =>
  conditions.filter((c) => isComplete(fields.find((f) => f.key === c.field) as FieldDef<unknown> | undefined, c)).length;

/** A sensible first condition for a field. */
export function newCondition<T>(field: FieldDef<T>, id: string): Condition {
  const op = OPERATORS[field.kind][0] ?? 'contains';
  return { id, field: field.key, op, ...(field.kind === 'choice' ? { value: [] as string[] } : {}) };
}

/** Sort accessors for every sortable field, so any column can be the sort key. */
export function accessorsFor<T>(fields: readonly FieldDef<T>[]): SortAccessors<T, string> {
  const out: Record<string, (item: T) => SortValue> = {};
  for (const f of fields) {
    if (f.sortable === false) continue;
    out[f.key] = (item: T) => {
      const v = f.get(item);
      if (Array.isArray(v)) return v.join(', ');
      // Choices sort in their natural order (e.g. urgent → low), not alphabetically.
      if (f.kind === 'choice' && typeof v === 'string') {
        const index = f.options?.findIndex((o) => o.value === v) ?? -1;
        return index >= 0 ? index : v;
      }
      return v as SortValue;
    };
  }
  return out;
}
