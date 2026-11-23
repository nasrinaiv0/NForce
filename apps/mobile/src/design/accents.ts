import { contrast, hslToHex, withAlpha } from './color';
import type { ColorScheme, Flavor, Palette } from './tokens';

/**
 * User-selectable accent colors. Each accent derives the brand-colored tokens
 * for both flavors and both schemes, searching lightness so text contrast
 * meets WCAG AA (verified for every combination in test/accents.test.ts).
 */
export const ACCENTS = {
  /** Brand: teal and navy from the NForce logo. */
  nforce: { hue: 184, sat: 34 },
  indigo: { hue: 231, sat: 100 },
  blue: { hue: 211, sat: 100 },
  teal: { hue: 178, sat: 80 },
  green: { hue: 142, sat: 64 },
  orange: { hue: 24, sat: 95 },
  rose: { hue: 343, sat: 82 },
  violet: { hue: 268, sat: 80 },
  graphite: { hue: 220, sat: 9 },
} as const;

export type AccentId = keyof typeof ACCENTS;
export const ACCENT_IDS = Object.keys(ACCENTS) as [AccentId, ...AccentId[]];

type AccentTokens = Pick<
  Palette,
  'primary' | 'onPrimary' | 'primaryContainer' | 'onPrimaryContainer' | 'tonal' | 'onTonal' | 'ripple' | 'heroStart' | 'heroEnd'
>;

/** Lightness that satisfies `ok`, searched from `from` in `step` increments. */
function findLightness(h: number, s: number, from: number, step: number, ok: (hex: string) => boolean): number {
  for (let l = from; l >= 5 && l <= 95; l += step) if (ok(hslToHex(h, s, l))) return l;
  return from;
}

export function accentTokens(accent: AccentId, flavor: Flavor, scheme: ColorScheme, base: Palette): AccentTokens {
  const { hue: h, sat: s } = ACCENTS[accent];
  const hero2 = h + (accent === 'graphite' ? 0 : 32);

  if (scheme === 'light') {
    // Primary must read as text on the page (4.5:1) and carry white labels.
    const l = findLightness(h, s, 52, -1, (hex) => contrast(hex, base.background) >= 4.5 && contrast('#FFFFFF', hex) >= 4.5);
    const primary = hslToHex(h, s, l);
    const ios = flavor === 'ios';
    const container = ios ? withAlpha(primary, 0.12) : hslToHex(h, Math.min(s, 100), 92);
    const onContainer = hslToHex(h, s, Math.max(12, l - (ios ? 12 : 28)));
    return {
      primary,
      onPrimary: '#FFFFFF',
      primaryContainer: container,
      onPrimaryContainer: onContainer,
      tonal: ios ? container : hslToHex(h, Math.min(s, 40), 90),
      onTonal: ios ? onContainer : hslToHex(h, Math.min(s, 50), 14),
      ripple: withAlpha(primary, 0.12),
      heroStart: primary,
      heroEnd: hslToHex(hero2, s, Math.max(30, l - 2)),
    };
  }

  if (flavor === 'ios') {
    // iOS dark: vivid tint on black with white bold labels (≥3:1, large text).
    const l = findLightness(h, s, 60, 1, (hex) => contrast(hex, base.background) >= 4.5);
    const primary = hslToHex(h, s, l);
    const safe = contrast('#FFFFFF', primary) >= 3 ? primary : hslToHex(h, s, findLightness(h, s, l, -1, (hex) => contrast('#FFFFFF', hex) >= 3 && contrast(hex, base.background) >= 3));
    return {
      primary: safe,
      onPrimary: '#FFFFFF',
      primaryContainer: withAlpha(safe, 0.24),
      onPrimaryContainer: hslToHex(h, s, 82),
      tonal: withAlpha(safe, 0.24),
      onTonal: hslToHex(h, s, 82),
      ripple: withAlpha(safe, 0.2),
      heroStart: hslToHex(h, s, 42),
      heroEnd: hslToHex(hero2, s, 36),
    };
  }

  // Material 3 dark: light tone-80 primary with dark tone-20 labels.
  return {
    primary: hslToHex(h, Math.min(s, 100), 80),
    onPrimary: hslToHex(h, Math.min(s, 100), 18),
    primaryContainer: hslToHex(h, Math.min(s, 60), 30),
    onPrimaryContainer: hslToHex(h, Math.min(s, 100), 90),
    tonal: hslToHex(h, Math.min(s, 15), 30),
    onTonal: hslToHex(h, Math.min(s, 50), 90),
    ripple: withAlpha(hslToHex(h, s, 80), 0.16),
    heroStart: hslToHex(h, Math.min(s, 70), 40),
    heroEnd: hslToHex(hero2, Math.min(s, 70), 34),
  };
}

/** Logo gradient (teal face → navy face) for brand moments. */
const BRAND_HERO: Readonly<Record<ColorScheme, [string, string]>> = {
  light: ['#3F8D91', '#1F3253'],
  dark: ['#2C6A6E', '#18263F'],
};

/** Apply an accent to a base palette. `indigo` keeps the original hand-tuned palette. */
export function applyAccent(base: Palette, accent: AccentId, flavor: Flavor, scheme: ColorScheme): Palette {
  if (accent === 'indigo') return base;
  const tokens = accentTokens(accent, flavor, scheme, base);
  if (accent === 'nforce') {
    const [heroStart, heroEnd] = BRAND_HERO[scheme];
    return { ...base, ...tokens, heroStart, heroEnd };
  }
  return { ...base, ...tokens };
}
