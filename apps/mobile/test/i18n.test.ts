import { describe, expect, it } from 'vitest';

import { createI18n, resolveLocale } from '@/i18n/core';
import { en } from '@/i18n/en';
import { es } from '@/i18n/es';
import { fil } from '@/i18n/fil';

const placeholders = (s: string) => [...s.matchAll(/\{(\w+)\}/g)].map((m) => m[1]).sort();

describe('translations', () => {
  it.each([
    ['es', es],
    ['fil', fil],
  ] as const)('%s has every key with matching placeholders and no blanks', (_name, dict) => {
    expect(Object.keys(dict).sort()).toEqual(Object.keys(en).sort());
    for (const [key, value] of Object.entries(en)) {
      const translated = dict[key as keyof typeof en];
      expect(translated.trim().length, key).toBeGreaterThan(0);
      expect(placeholders(translated), key).toEqual(placeholders(value));
    }
  });

  it('defines both plural forms for every pluralized key', () => {
    for (const key of Object.keys(en)) {
      if (key.endsWith('_one')) expect(Object.keys(en)).toContain(key.replace(/_one$/, '_other'));
    }
  });
});

describe('createI18n', () => {
  it('interpolates and pluralizes', () => {
    const i = createI18n('en', 'en-US');
    expect(i.t('home.morning', { name: 'Maya' })).toBe('Good morning, Maya');
    expect(i.plural('timeoff.days', 1)).toBe('1 day');
    expect(i.plural('timeoff.days', 2.5)).toBe('2.5 days');
    expect(i.t('home.morning')).toBe('Good morning, {name}');
  });

  it('formats calendar dates without time-zone drift and times in the org zone', () => {
    const i = createI18n('en', 'en-US');
    expect(i.date('2026-11-23', { weekday: 'long', month: 'long', day: 'numeric' })).toBe('Monday, November 23');
    expect(i.time('2026-11-23T01:00:00Z', 'Asia/Manila')).toMatch(/^9:00\s?AM$/);
    expect(i.relative('2026-11-23T00:00:00Z', new Date('2026-11-23T00:42:00Z'))).toMatch(/42 min/);
  });

  it('uses the device region when it matches the chosen language', () => {
    expect(createI18n('en', 'en-PH').tag).toBe('en-PH');
    expect(createI18n('es', 'en-PH').tag).toBe('es-ES');
    expect(createI18n('es', 'es-MX').t('tabs.home')).toBe('Inicio');
  });

  it('resolves the locale from preference or device', () => {
    expect(resolveLocale('system', 'tl')).toBe('fil');
    expect(resolveLocale('system', 'es')).toBe('es');
    expect(resolveLocale('system', 'de')).toBe('en');
    expect(resolveLocale('fil', 'en')).toBe('fil');
  });
});
