import { readFileSync, readdirSync } from 'node:fs';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';

import { PERMISSIONS, ROLE_GRANTS, ROLE_TEMPLATES, mergeGrants } from '../src';

/**
 * Drift guard: the permission catalog and role templates seeded in SQL must
 * match @nforce/core exactly, so the server policy and client UI never
 * disagree about who may do what.
 */
const migrationsDir = join(__dirname, '../../../supabase/migrations');
const sql = readdirSync(migrationsDir)
  .filter((f) => f.endsWith('.sql'))
  .sort()
  .map((f) => readFileSync(join(migrationsDir, f), 'utf8'))
  .join('\n');

// Template re-syncs ship as new migrations, so the LAST seed block is authoritative.
const block = (start: string) => {
  const from = sql.lastIndexOf(start);
  if (from < 0) throw new Error(`Missing seed block: ${start}`);
  return sql.slice(from, sql.indexOf(';', from));
};

describe('SQL seed parity', () => {
  it('seeds exactly the core permission catalog', () => {
    const seeded = [...block('insert into public.permissions').matchAll(/\('([a-z_.]+)'\)/g)].map((m) => m[1]);
    expect(seeded.sort()).toEqual([...PERMISSIONS].sort());
  });

  it('seeds exactly the core role templates and grants', () => {
    const roles = [...block('insert into public.roles').matchAll(/\(null, '([a-z_]+)'/g)].map((m) => m[1]);
    expect(roles.sort()).toEqual([...ROLE_TEMPLATES].sort());

    const seeded = [...block('insert into public.role_grants').matchAll(/\('([a-z_]+)', '([a-z_.]+)', '([a-z]+)'\)/g)]
      .map((m) => `${m[1]}|${m[2]}|${m[3]}`)
      .sort();
    const expected = ROLE_TEMPLATES.flatMap((r) => [...mergeGrants(ROLE_GRANTS[r])].map(([p, s]) => `${r}|${p}|${s}`)).sort();
    expect(seeded).toEqual(expected);
  });
});
