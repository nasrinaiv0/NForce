/** Pure, framework-free i18n: dictionaries, plurals and Intl formatting. */
import { parseDateKey, type DateKey } from '@nforce/core';
import { en, type MessageKey, type Messages } from './en';
import { es } from './es';
import { fil } from './fil';

export type Locale = 'en' | 'fil' | 'es';
export const LOCALES: readonly { id: Locale; native: string }[] = [
  { id: 'en', native: 'English' },
  { id: 'fil', native: 'Filipino' },
  { id: 'es', native: 'Español' },
];

const DICTIONARIES: Readonly<Record<Locale, Messages>> = { en, fil, es };

type Params = Readonly<Record<string, string | number>>;

const interpolate = (template: string, params?: Params) =>
  params === undefined ? template : template.replace(/\{(\w+)\}/g, (m, k: string) => (k in params ? String(params[k]) : m));

export interface I18n {
  readonly locale: Locale;
  /** BCP-47 tag used for Intl formatting, e.g. `en-PH`. */
  readonly tag: string;
  t(key: MessageKey, params?: Params): string;
  /** Pluralized message: looks up `${base}_one` / `${base}_other`. */
  plural(base: string, count: number, params?: Params): string;
  time(iso: string, timeZone: string): string;
  date(key: DateKey, options?: Intl.DateTimeFormatOptions): string;
  number(value: number, options?: Intl.NumberFormatOptions): string;
  relative(fromIso: string, now: Date): string;
}

export function createI18n(locale: Locale, deviceTag: string): I18n {
  const dict = DICTIONARIES[locale];
  const tag = deviceTag.toLowerCase().startsWith(locale === 'fil' ? 'fil' : locale) ? deviceTag : { en: 'en-US', fil: 'fil-PH', es: 'es-ES' }[locale];
  const rules = new Intl.PluralRules(tag);
  const timeFmt = new Map<string, Intl.DateTimeFormat>();
  const t = (key: MessageKey, params?: Params) => interpolate(dict[key] ?? en[key], params);

  return {
    locale,
    tag,
    t,
    plural(base, count, params) {
      const form = rules.select(count) === 'one' ? 'one' : 'other';
      const key = `${base}_${form}` as MessageKey;
      return interpolate(dict[key] ?? en[key] ?? base, { count: new Intl.NumberFormat(tag).format(count), ...params });
    },
    time(iso, timeZone) {
      let f = timeFmt.get(timeZone);
      if (f === undefined) {
        f = new Intl.DateTimeFormat(tag, { hour: 'numeric', minute: '2-digit', timeZone });
        timeFmt.set(timeZone, f);
      }
      return f.format(new Date(iso));
    },
    date(key, options = { weekday: 'short', month: 'short', day: 'numeric' }) {
      const { year, month, day } = parseDateKey(key);
      // Noon UTC + UTC formatting: a calendar date never shifts across zones.
      return new Intl.DateTimeFormat(tag, { ...options, timeZone: 'UTC' }).format(new Date(Date.UTC(year, month - 1, day, 12)));
    },
    number: (value, options) => new Intl.NumberFormat(tag, options).format(value),
    relative(fromIso, now) {
      const minutes = Math.round((now.getTime() - Date.parse(fromIso)) / 60_000);
      const rtf = new Intl.RelativeTimeFormat(tag, { numeric: 'auto', style: 'short' });
      if (Math.abs(minutes) < 60) return rtf.format(-minutes, 'minute');
      const hours = Math.round(minutes / 60);
      if (Math.abs(hours) < 24) return rtf.format(-hours, 'hour');
      return rtf.format(-Math.round(hours / 24), 'day');
    },
  };
}

export function resolveLocale(preference: Locale | 'system', deviceLanguage: string | null | undefined): Locale {
  if (preference !== 'system') return preference;
  const lang = (deviceLanguage ?? 'en').toLowerCase();
  if (lang === 'fil' || lang === 'tl') return 'fil';
  if (lang === 'es') return 'es';
  return 'en';
}

export type { MessageKey, Messages };
