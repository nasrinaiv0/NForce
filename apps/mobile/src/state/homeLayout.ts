import type { HomeWidget } from '@nforce/core';

export interface HomeWidgetSlot {
  readonly widget: HomeWidget;
  readonly visible: boolean;
}

/**
 * Merge the permission-derived widget list with the user's saved order and
 * hidden set. Widgets the user may not see are never shown, whatever the
 * saved layout says; widgets newly granted are appended in default order.
 */
export function resolveHomeLayout(
  available: readonly HomeWidget[],
  savedOrder: readonly HomeWidget[],
  hidden: readonly HomeWidget[],
): HomeWidgetSlot[] {
  const allowed = new Set(available);
  const ordered = [...savedOrder.filter((w, i) => allowed.has(w) && savedOrder.indexOf(w) === i), ...available.filter((w) => !savedOrder.includes(w))];
  return ordered.map((widget) => ({ widget, visible: !hidden.includes(widget) }));
}
