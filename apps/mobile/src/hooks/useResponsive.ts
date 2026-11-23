import { Platform, useWindowDimensions } from 'react-native';

/**
 * Material 3 window size classes, used on every platform:
 * compact < 600 ≤ medium < 840 ≤ expanded < 1200 ≤ large.
 */
export type WindowClass = 'compact' | 'medium' | 'expanded' | 'large';

export interface Responsive {
  readonly width: number;
  readonly windowClass: WindowClass;
  /** Desktop/tablet-landscape layouts: multi-column content, tables. */
  readonly isDesktop: boolean;
  /** Navigation moves to a sidebar instead of a bottom bar. */
  readonly sidebar: boolean;
  /** Columns for card grids. */
  readonly columns: 1 | 2 | 3;
}

export function windowClassFor(width: number): WindowClass {
  if (width < 600) return 'compact';
  if (width < 840) return 'medium';
  if (width < 1200) return 'expanded';
  return 'large';
}

export function useResponsive(): Responsive {
  const { width } = useWindowDimensions();
  const windowClass = windowClassFor(width);
  const isDesktop = windowClass === 'expanded' || windowClass === 'large';
  // iOS uses the native iPad sidebar (NativeTabs sidebarAdaptable); web and
  // large Android screens use the NForce sidebar.
  const sidebar = Platform.OS !== 'ios' && windowClass !== 'compact';
  return { width, windowClass, isDesktop, sidebar, columns: windowClass === 'large' ? 3 : isDesktop ? 2 : 1 };
}
