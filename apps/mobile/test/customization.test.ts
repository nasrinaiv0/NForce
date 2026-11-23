import { describe, expect, it, vi } from 'vitest';

import { ACCENT_IDS, applyAccent } from '@/design/accents';
import { contrast, hslToHex, parseColor } from '@/design/color';
import { PALETTES, type ColorScheme, type Flavor } from '@/design/tokens';
import { resolveHomeLayout } from '@/state/homeLayout';

// tokens.ts reads Platform for font selection; stub it for Node (vi.mock is hoisted).
vi.mock('react-native', () => ({ Platform: { OS: 'ios', select: (o: { default?: unknown }) => o.default } }));

describe('color math', () => {
  it('converts and measures contrast correctly', () => {
    expect(hslToHex(0, 100, 50)).toBe('#FF0000');
    expect(parseColor('rgba(10,20,30,0.5)')).toEqual({ r: 10, g: 20, b: 30, a: 0.5 });
    expect(contrast('#000000', '#FFFFFF')).toBeCloseTo(21, 0);
    expect(contrast('#767676', '#FFFFFF')).toBeGreaterThanOrEqual(4.5);
  });
});

describe('accent palettes meet WCAG AA in every flavor and scheme', () => {
  const combos = ACCENT_IDS.flatMap((a) =>
    (['ios', 'android'] as Flavor[]).flatMap((f) => (['light', 'dark'] as ColorScheme[]).map((s) => [a, f, s] as const)),
  );
  it.each(combos)('%s · %s · %s', (accent, flavor, scheme) => {
    const base = PALETTES[flavor][scheme];
    const p = applyAccent(base, accent, flavor, scheme);
    // Links/tint text on the page background.
    expect(contrast(p.primary, p.background)).toBeGreaterThanOrEqual(4.5);
    // Bold button labels (large text ≥ 3:1; Material dark targets 4.5).
    expect(contrast(p.onPrimary, p.primary)).toBeGreaterThanOrEqual(flavor === 'android' ? 4.5 : 3);
    // Text on tinted containers, composited over the card surface.
    expect(contrast(p.onPrimaryContainer, p.primaryContainer, p.surface)).toBeGreaterThanOrEqual(4.5);
    expect(contrast(p.onTonal, p.tonal, p.surface)).toBeGreaterThanOrEqual(4.5);
  });
});

describe('home layout', () => {
  it('keeps saved order, appends new widgets and never shows disallowed ones', () => {
    const out = resolveHomeLayout(['clock', 'approvals', 'my_work', 'balances'], ['my_work', 'org_metrics', 'clock'], ['balances']);
    expect(out).toEqual([
      { widget: 'my_work', visible: true },
      { widget: 'clock', visible: true },
      { widget: 'approvals', visible: true },
      { widget: 'balances', visible: false },
    ]);
  });
});
