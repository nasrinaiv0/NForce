import { describe, expect, it } from 'vitest';
import { compareValues, facetCounts, foldText, queryList, searchItems, sortItems } from '../src';

interface Row { name: string; hours?: number; team: string }
const rows: Row[] = [
  { name: 'Zoë', hours: 40, team: 'A' },
  { name: 'adam', hours: 38.5, team: 'B' },
  { name: 'José', team: 'A' },
  { name: 'Ana 10', hours: 40, team: 'B' },
  { name: 'Ana 2', hours: 12, team: 'A' },
];
const accessors = { name: (r: Row) => r.name, hours: (r: Row) => r.hours };

describe('sortItems', () => {
  it('sorts locale-aware, case-insensitive and numeric', () => {
    expect(sortItems(rows, accessors, { key: 'name', direction: 'asc' }).map((r) => r.name)).toEqual(['adam', 'Ana 2', 'Ana 10', 'José', 'Zoë']);
  });

  it('keeps missing values last in both directions and is stable', () => {
    expect(sortItems(rows, accessors, { key: 'hours', direction: 'desc' }).map((r) => r.name)).toEqual(['Zoë', 'Ana 10', 'adam', 'Ana 2', 'José']);
    expect(sortItems(rows, accessors, { key: 'hours', direction: 'asc' }).map((r) => r.name)).toEqual(['Ana 2', 'adam', 'Zoë', 'Ana 10', 'José']);
  });

  it('does not mutate the input', () => {
    const copy = [...rows];
    sortItems(rows, accessors, { key: 'name', direction: 'desc' });
    expect(rows).toEqual(copy);
  });
});

describe('search and query', () => {
  it('matches accent- and case-insensitively, requiring every term', () => {
    expect(foldText('José Ñandú')).toBe('jose nandu');
    expect(searchItems(rows, 'jose', (r) => [r.name]).map((r) => r.name)).toEqual(['José']);
    expect(searchItems(rows, 'ana b', (r) => [r.name, r.team]).map((r) => r.name)).toEqual(['Ana 10']);
    expect(searchItems(rows, '   ', (r) => [r.name])).toHaveLength(5);
  });

  it('applies filters, search, then sort', () => {
    const out = queryList(rows, {
      filters: [(r) => r.team === 'A', (r) => r.hours !== undefined],
      search: { text: 'a', fields: (r) => [r.name] },
      sort: { key: 'hours', direction: 'asc' },
      accessors,
    });
    expect(out.map((r) => r.name)).toEqual(['Ana 2']);
    expect(queryList(rows, {}).length).toBe(5);
  });

  it('counts facets and compares mixed values', () => {
    expect(facetCounts(rows, (r) => r.team)).toEqual(new Map([['A', 3], ['B', 2]]));
    const c = new Intl.Collator('en');
    expect(compareValues(undefined, 1, c)).toBe(1);
    expect(compareValues(true, false, c)).toBe(1);
    expect(compareValues(null, '', c)).toBe(0);
  });
});
