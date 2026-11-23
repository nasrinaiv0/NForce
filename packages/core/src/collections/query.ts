/**
 * List querying: filter → search → sort, shared by every list in every client.
 *
 * - Sorting is stable, locale-aware (Intl.Collator, numeric) and always puts
 *   missing values last regardless of direction.
 * - Search is case- and accent-insensitive ("jose" matches "José") and every
 *   whitespace-separated term must match one of the item's fields.
 */

export type SortDirection = 'asc' | 'desc';
export type SortValue = string | number | boolean | null | undefined;

export interface SortSpec<K extends string = string> {
  readonly key: K;
  readonly direction: SortDirection;
}

export type SortAccessors<T, K extends string> = Readonly<Record<K, (item: T) => SortValue>>;

export interface ListQuery<T, K extends string> {
  readonly filters?: readonly ((item: T) => boolean)[];
  readonly search?: { readonly text: string; readonly fields: (item: T) => readonly (string | undefined)[] };
  readonly sort?: SortSpec<K>;
  readonly accessors?: SortAccessors<T, K>;
  readonly locale?: string;
}

const collators = new Map<string, Intl.Collator>();
const collatorFor = (locale = 'en') => {
  let c = collators.get(locale);
  if (c === undefined) {
    c = new Intl.Collator(locale, { sensitivity: 'base', numeric: true });
    collators.set(locale, c);
  }
  return c;
};

/** Lowercase and strip diacritics for forgiving matching. */
export const foldText = (s: string): string =>
  s
    .normalize('NFD')
    .replace(/[̀-ͯ]/g, '')
    .toLowerCase();

export function compareValues(a: SortValue, b: SortValue, collator: Intl.Collator): number {
  const aMissing = a === undefined || a === null || a === '';
  const bMissing = b === undefined || b === null || b === '';
  if (aMissing || bMissing) return aMissing === bMissing ? 0 : aMissing ? 1 : -1;
  if (typeof a === 'number' && typeof b === 'number') return a - b;
  if (typeof a === 'boolean' && typeof b === 'boolean') return Number(a) - Number(b);
  return collator.compare(String(a), String(b));
}

export function sortItems<T, K extends string>(
  items: readonly T[],
  accessors: SortAccessors<T, K>,
  spec: SortSpec<K>,
  locale?: string,
): T[] {
  const collator = collatorFor(locale);
  const get = accessors[spec.key];
  const sign = spec.direction === 'asc' ? 1 : -1;
  return items
    .map((item, index) => ({ item, index, value: get(item) }))
    .sort((x, y) => {
      const missingX = x.value === undefined || x.value === null || x.value === '';
      const missingY = y.value === undefined || y.value === null || y.value === '';
      if (missingX !== missingY) return missingX ? 1 : -1; // missing last in both directions
      return sign * compareValues(x.value, y.value, collator) || x.index - y.index;
    })
    .map((x) => x.item);
}

export function searchItems<T>(
  items: readonly T[],
  text: string,
  fields: (item: T) => readonly (string | undefined)[],
): T[] {
  const terms = foldText(text).split(/\s+/).filter(Boolean);
  if (terms.length === 0) return [...items];
  return items.filter((item) => {
    const haystack = fields(item)
      .filter((f): f is string => typeof f === 'string')
      .map(foldText);
    return terms.every((term) => haystack.some((h) => h.includes(term)));
  });
}

/** Apply filters (AND), then search, then sort. Never mutates the input. */
export function queryList<T, K extends string>(items: readonly T[], query: ListQuery<T, K>): T[] {
  let out = (query.filters ?? []).reduce<T[]>((acc, f) => acc.filter(f), [...items]);
  if (query.search !== undefined) out = searchItems(out, query.search.text, query.search.fields);
  if (query.sort !== undefined && query.accessors !== undefined) out = sortItems(out, query.accessors, query.sort, query.locale);
  return out;
}

/** Count items per facet value, e.g. for filter-chip badges. */
export function facetCounts<T, V extends string>(items: readonly T[], facet: (item: T) => V): Map<V, number> {
  const counts = new Map<V, number>();
  for (const item of items) {
    const v = facet(item);
    counts.set(v, (counts.get(v) ?? 0) + 1);
  }
  return counts;
}
