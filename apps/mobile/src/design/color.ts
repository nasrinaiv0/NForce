/**
 * Small, dependency-free color math used to derive accent palettes and to
 * verify WCAG contrast in tests.
 */

export interface Rgba {
  readonly r: number;
  readonly g: number;
  readonly b: number;
  readonly a: number;
}

const clamp01 = (n: number) => Math.min(1, Math.max(0, n));

export function parseColor(input: string): Rgba {
  const s = input.trim().toLowerCase();
  const hex = /^#([0-9a-f]{3}|[0-9a-f]{6})$/.exec(s);
  if (hex !== null) {
    const h = hex[1] ?? '';
    const full = h.length === 3 ? [...h].map((c) => c + c).join('') : h;
    return { r: parseInt(full.slice(0, 2), 16), g: parseInt(full.slice(2, 4), 16), b: parseInt(full.slice(4, 6), 16), a: 1 };
  }
  const rgb = /^rgba?\(([^)]+)\)$/.exec(s);
  if (rgb !== null) {
    const [r = 0, g = 0, b = 0, a = 1] = (rgb[1] ?? '').split(',').map((x) => Number(x.trim()));
    return { r, g, b, a };
  }
  throw new Error(`Unsupported color: ${input}`);
}

export function hslToHex(h: number, s: number, l: number): string {
  const hue = ((h % 360) + 360) % 360;
  const sat = clamp01(s / 100);
  const lig = clamp01(l / 100);
  const k = (n: number) => (n + hue / 30) % 12;
  const a = sat * Math.min(lig, 1 - lig);
  const f = (n: number) => lig - a * Math.max(-1, Math.min(k(n) - 3, Math.min(9 - k(n), 1)));
  const to = (x: number) => Math.round(x * 255).toString(16).padStart(2, '0');
  return `#${to(f(0))}${to(f(8))}${to(f(4))}`.toUpperCase();
}

export const withAlpha = (hex: string, alpha: number): string => {
  const { r, g, b } = parseColor(hex);
  return `rgba(${r},${g},${b},${alpha})`;
};

/** Composite a (possibly translucent) color over an opaque background. */
export function composite(fg: string, bg: string): Rgba {
  const f = parseColor(fg);
  const b = parseColor(bg);
  const mix = (x: number, y: number) => x * f.a + y * (1 - f.a);
  return { r: mix(f.r, b.r), g: mix(f.g, b.g), b: mix(f.b, b.b), a: 1 };
}

const channel = (c: number) => {
  const v = c / 255;
  return v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4;
};
export const luminance = ({ r, g, b }: Rgba): number => 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b);

/** WCAG 2.x contrast ratio; translucent colors are composited over `bg`. */
export function contrast(fg: string, bg: string, base = '#FFFFFF'): number {
  const back = composite(bg, base);
  const backHex = `rgb(${back.r},${back.g},${back.b})`;
  const front = composite(fg, backHex);
  const [l1, l2] = [luminance(front), luminance(back)].sort((x, y) => y - x) as [number, number];
  return (l1 + 0.05) / (l2 + 0.05);
}
