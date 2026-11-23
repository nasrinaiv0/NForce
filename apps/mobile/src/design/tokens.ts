import { Platform, type TextStyle } from 'react-native';

/**
 * NForce design tokens.
 *
 * One semantic vocabulary, two native "flavors":
 * - `ios`     follows Apple's Human Interface Guidelines (grouped surfaces,
 *             SF type ramp, hairline separators, capsule controls).
 * - `android` follows Material Design 3 (tonal surfaces, M3 type scale,
 *             state layers / ripples, large rounded shapes).
 *
 * Components consume ONLY these semantic tokens, never raw hex values, so
 * brand changes, dark mode and per-tenant theming stay a one-file change.
 */

export type Flavor = 'ios' | 'android';
export type ColorScheme = 'light' | 'dark';

export interface Palette {
  readonly background: string;
  readonly surface: string;
  readonly surfaceRaised: string;
  readonly fill: string;
  readonly text: string;
  readonly textSecondary: string;
  readonly textTertiary: string;
  readonly onPrimary: string;
  readonly primary: string;
  readonly primaryContainer: string;
  readonly onPrimaryContainer: string;
  /** Secondary emphasis (iOS tinted / M3 secondary container). */
  readonly tonal: string;
  readonly onTonal: string;
  readonly separator: string;
  readonly outline: string;
  readonly success: string;
  readonly successContainer: string;
  readonly warning: string;
  readonly warningContainer: string;
  readonly danger: string;
  readonly dangerContainer: string;
  readonly info: string;
  readonly infoContainer: string;
  readonly ripple: string;
  readonly scrim: string;
  /** Hero gradient stops (brand moments only). */
  readonly heroStart: string;
  readonly heroEnd: string;
}

const iosLight: Palette = {
  background: '#F2F2F7',
  surface: '#FFFFFF',
  surfaceRaised: '#FFFFFF',
  fill: 'rgba(118,118,128,0.12)',
  text: '#000000',
  textSecondary: 'rgba(60,60,67,0.64)',
  textTertiary: 'rgba(60,60,67,0.36)',
  onPrimary: '#FFFFFF',
  primary: '#3A5BFF',
  primaryContainer: 'rgba(58,91,255,0.12)',
  onPrimaryContainer: '#2443E0',
  tonal: 'rgba(58,91,255,0.12)',
  onTonal: '#2443E0',
  separator: 'rgba(60,60,67,0.22)',
  outline: 'rgba(60,60,67,0.29)',
  success: '#248A3D',
  successContainer: 'rgba(52,199,89,0.16)',
  warning: '#C93400',
  warningContainer: 'rgba(255,149,0,0.16)',
  danger: '#D70015',
  dangerContainer: 'rgba(255,59,48,0.14)',
  info: '#0071A4',
  infoContainer: 'rgba(50,173,230,0.16)',
  ripple: 'rgba(0,0,0,0.08)',
  scrim: 'rgba(0,0,0,0.4)',
  heroStart: '#3A5BFF',
  heroEnd: '#7B3CFF',
};

const iosDark: Palette = {
  background: '#000000',
  surface: '#1C1C1E',
  surfaceRaised: '#2C2C2E',
  fill: 'rgba(118,118,128,0.24)',
  text: '#FFFFFF',
  textSecondary: 'rgba(235,235,245,0.64)',
  textTertiary: 'rgba(235,235,245,0.32)',
  onPrimary: '#FFFFFF',
  primary: '#6683FF',
  primaryContainer: 'rgba(102,131,255,0.22)',
  onPrimaryContainer: '#A9BAFF',
  tonal: 'rgba(102,131,255,0.22)',
  onTonal: '#A9BAFF',
  separator: 'rgba(84,84,88,0.6)',
  outline: 'rgba(84,84,88,0.8)',
  success: '#30D158',
  successContainer: 'rgba(48,209,88,0.2)',
  warning: '#FF9F0A',
  warningContainer: 'rgba(255,159,10,0.2)',
  danger: '#FF6961',
  dangerContainer: 'rgba(255,69,58,0.22)',
  info: '#64D2FF',
  infoContainer: 'rgba(100,210,255,0.2)',
  ripple: 'rgba(255,255,255,0.12)',
  scrim: 'rgba(0,0,0,0.6)',
  heroStart: '#3049D6',
  heroEnd: '#6429D9',
};

/** Material 3 tonal scheme generated around the NForce seed (#3A5BFF). */
const androidLight: Palette = {
  background: '#FBF8FF',
  surface: '#F4F2FA',
  surfaceRaised: '#FFFFFF',
  fill: '#E8E7F0',
  text: '#1A1B21',
  textSecondary: '#45464F',
  textTertiary: '#767680',
  onPrimary: '#FFFFFF',
  primary: '#3653D6',
  primaryContainer: '#DDE1FF',
  onPrimaryContainer: '#001552',
  tonal: '#DFE1F9',
  onTonal: '#171B2C',
  separator: '#C6C5D0',
  outline: '#767680',
  success: '#1E6C32',
  successContainer: '#B7F1BE',
  warning: '#8A5100',
  warningContainer: '#FFDCBD',
  danger: '#BA1A1A',
  dangerContainer: '#FFDAD6',
  info: '#00658E',
  infoContainer: '#C7E7FF',
  ripple: 'rgba(54,83,214,0.12)',
  scrim: 'rgba(0,0,0,0.32)',
  heroStart: '#3653D6',
  heroEnd: '#6A3FD8',
};

const androidDark: Palette = {
  background: '#121318',
  surface: '#1E1F25',
  surfaceRaised: '#292A2F',
  fill: '#34343A',
  text: '#E3E1E9',
  textSecondary: '#C6C5D0',
  textTertiary: '#90909A',
  onPrimary: '#00237F',
  primary: '#B9C3FF',
  primaryContainer: '#1C3BBE',
  onPrimaryContainer: '#DDE1FF',
  tonal: '#41465A',
  onTonal: '#DFE1F9',
  separator: '#45464F',
  outline: '#90909A',
  success: '#9CD5A3',
  successContainer: '#005321',
  warning: '#FFB870',
  warningContainer: '#693C00',
  danger: '#FFB4AB',
  dangerContainer: '#93000A',
  info: '#85CFFF',
  infoContainer: '#004C6C',
  ripple: 'rgba(185,195,255,0.16)',
  scrim: 'rgba(0,0,0,0.5)',
  heroStart: '#2A47C9',
  heroEnd: '#5B33C2',
};

export const PALETTES: Readonly<Record<Flavor, Readonly<Record<ColorScheme, Palette>>>> = {
  ios: { light: iosLight, dark: iosDark },
  android: { light: androidLight, dark: androidDark },
};

/** 4-pt spacing grid. */
export const space = { xxs: 2, xs: 4, sm: 8, md: 12, lg: 16, xl: 20, xxl: 24, xxxl: 32, huge: 48 } as const;

export interface Shape {
  readonly card: number;
  readonly control: number;
  readonly button: number;
  readonly chip: number;
  readonly sheet: number;
  readonly buttonHeight: number;
  readonly rowMinHeight: number;
  readonly hairline: number;
}

export const SHAPES: Readonly<Record<Flavor, Shape>> = {
  // iOS 26 era: softer, larger continuous corners and capsule buttons.
  ios: { card: 22, control: 12, button: 999, chip: 999, sheet: 28, buttonHeight: 50, rowMinHeight: 48, hairline: 0.5 },
  // M3 shape scale: medium 12, large 16, extra-large 28; full for buttons.
  android: { card: 20, control: 12, button: 999, chip: 8, sheet: 28, buttonHeight: 48, rowMinHeight: 56, hairline: 1 },
};

export type TypeVariant =
  | 'display'
  | 'largeTitle'
  | 'title'
  | 'title2'
  | 'headline'
  | 'body'
  | 'callout'
  | 'subhead'
  | 'footnote'
  | 'caption'
  | 'label';

type Ramp = Readonly<Record<TypeVariant, TextStyle>>;

const fontFamily = Platform.select({ web: 'system-ui, -apple-system, "Segoe UI", Roboto, sans-serif', default: undefined });
const f = (fontSize: number, lineHeight: number, fontWeight: TextStyle['fontWeight'], letterSpacing = 0): TextStyle => ({
  fontSize,
  lineHeight,
  fontWeight,
  letterSpacing,
  ...(fontFamily !== undefined ? { fontFamily } : {}),
});

/** Apple HIG default (Large) Dynamic Type sizes. */
const iosRamp: Ramp = {
  display: f(56, 60, '700', -1.2),
  largeTitle: f(34, 41, '700', 0.4),
  title: f(28, 34, '700', 0.38),
  title2: f(22, 28, '700', -0.26),
  headline: f(17, 22, '600', -0.43),
  body: f(17, 22, '400', -0.43),
  callout: f(16, 21, '400', -0.31),
  subhead: f(15, 20, '400', -0.23),
  footnote: f(13, 18, '400', -0.08),
  caption: f(12, 16, '400', 0),
  label: f(13, 18, '600', -0.08),
};

/** Material 3 type scale. */
const androidRamp: Ramp = {
  display: f(57, 64, '400', -0.25),
  largeTitle: f(32, 40, '400', 0),
  title: f(28, 36, '400', 0),
  title2: f(22, 28, '500', 0),
  headline: f(16, 24, '500', 0.15),
  body: f(16, 24, '400', 0.5),
  callout: f(15, 22, '400', 0.25),
  subhead: f(14, 20, '400', 0.25),
  footnote: f(12, 16, '400', 0.4),
  caption: f(11, 16, '500', 0.5),
  label: f(14, 20, '500', 0.1),
};

export const TYPE_RAMPS: Readonly<Record<Flavor, Ramp>> = { ios: iosRamp, android: androidRamp };

/** Motion durations (ms) from the architecture's motion guidance. */
export const motion = {
  press: 120,
  hover: 150,
  popover: 180,
  modal: 220,
  page: 200,
  emphasis: 360,
} as const;

/** Minimum touch target (HIG 44pt, M3 48dp). */
export const MIN_TOUCH: Readonly<Record<Flavor, number>> = { ios: 44, android: 48 };
