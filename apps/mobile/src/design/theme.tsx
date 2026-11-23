import { createContext, useContext, useEffect, useMemo, useState, type ReactNode } from 'react';
import { AccessibilityInfo, Platform, useColorScheme } from 'react-native';

import { usePreference } from '@/state/preferences';
import {
  MIN_TOUCH,
  PALETTES,
  SHAPES,
  TYPE_RAMPS,
  motion,
  space,
  type ColorScheme,
  type Flavor,
  type Palette,
  type Shape,
} from './tokens';

export interface Theme {
  readonly flavor: Flavor;
  readonly scheme: ColorScheme;
  readonly colors: Palette;
  readonly shape: Shape;
  readonly type: (typeof TYPE_RAMPS)[Flavor];
  readonly space: typeof space;
  readonly motion: typeof motion;
  readonly minTouch: number;
  /** True when the OS or the user asked for reduced motion. */
  readonly reduceMotion: boolean;
}

const ThemeContext = createContext<Theme | null>(null);

function platformFlavor(): Flavor {
  if (Platform.OS === 'android') return 'android';
  if (Platform.OS === 'web' && typeof window !== 'undefined') {
    // Design-review override for web previews: ?flavor=android
    const q = new URLSearchParams(window.location.search).get('flavor');
    if (q === 'android' || q === 'ios') return q;
  }
  return 'ios';
}

function useSystemReduceMotion(): boolean {
  const [reduce, setReduce] = useState(false);
  useEffect(() => {
    let alive = true;
    AccessibilityInfo.isReduceMotionEnabled()
      .then((v) => alive && setReduce(v))
      .catch(() => undefined);
    const sub = AccessibilityInfo.addEventListener('reduceMotionChanged', setReduce);
    return () => {
      alive = false;
      sub.remove();
    };
  }, []);
  return reduce;
}

export function ThemeProvider({ children }: { children: ReactNode }) {
  const system = useColorScheme();
  const appearance = usePreference('appearance');
  const flavorPref = usePreference('flavor');
  const userReduceMotion = usePreference('reduceMotion');
  const systemReduceMotion = useSystemReduceMotion();

  const theme = useMemo<Theme>(() => {
    const scheme: ColorScheme = appearance === 'system' ? (system === 'dark' ? 'dark' : 'light') : appearance;
    const flavor: Flavor = flavorPref === 'auto' ? platformFlavor() : flavorPref;
    return {
      flavor,
      scheme,
      colors: PALETTES[flavor][scheme],
      shape: SHAPES[flavor],
      type: TYPE_RAMPS[flavor],
      space,
      motion,
      minTouch: MIN_TOUCH[flavor],
      reduceMotion: systemReduceMotion || userReduceMotion,
    };
  }, [appearance, system, flavorPref, systemReduceMotion, userReduceMotion]);

  return <ThemeContext.Provider value={theme}>{children}</ThemeContext.Provider>;
}

export function useTheme(): Theme {
  const theme = useContext(ThemeContext);
  if (theme === null) throw new Error('useTheme must be used inside <ThemeProvider>.');
  return theme;
}
