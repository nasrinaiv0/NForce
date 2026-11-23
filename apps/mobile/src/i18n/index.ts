import { useLocales } from 'expo-localization';
import { useMemo } from 'react';

import { usePreference } from '@/state/preferences';
import { createI18n, resolveLocale, type I18n } from './core';

export { LOCALES, createI18n, resolveLocale } from './core';
export type { I18n, Locale, MessageKey } from './core';

export function useI18n(): I18n {
  const preference = usePreference('locale');
  const [device] = useLocales();
  const locale = resolveLocale(preference, device.languageCode);
  const deviceTag = device.languageTag;
  return useMemo(() => createI18n(locale, deviceTag), [locale, deviceTag]);
}

