import type { HomeWidget } from '@nforce/core';
import { StyleSheet, View } from 'react-native';

import { Button } from '@/components/Button';
import { SegmentedControl, Toggle } from '@/components/Controls';
import { HeroCard } from '@/components/Hero';
import { Icon, type IconName } from '@/components/Icon';
import { Screen } from '@/components/Screen';
import { Card, ListSection } from '@/components/Surface';
import { Text } from '@/components/Text';
import { Touchable } from '@/components/Touchable';
import { useSession } from '@/data/queries';
import { ACCENT_IDS, applyAccent, type AccentId } from '@/design/accents';
import { useTheme } from '@/design/theme';
import { PALETTES } from '@/design/tokens';
import { useResponsive } from '@/hooks/useResponsive';
import { useI18n } from '@/i18n';
import { resetAppearance, setPreference, usePreference } from '@/state/preferences';
import { resolveHomeLayout } from '@/state/homeLayout';

const WIDGET_ICON: Readonly<Record<HomeWidget, IconName>> = {
  clock: 'clock',
  approvals: 'approvals',
  next_shift: 'schedule',
  team_pulse: 'team',
  org_metrics: 'reports',
  my_work: 'work',
  balances: 'timeoff',
};

export default function CustomizeScreen() {
  const t = useTheme();
  const i18n = useI18n();
  const { isDesktop } = useResponsive();
  const session = useSession();
  const appearance = usePreference('appearance');
  const accent = usePreference('accent');
  const density = usePreference('density');
  const flavor = usePreference('flavor');
  const sidebar = usePreference('sidebar');
  const order = usePreference('homeOrder');
  const hidden = usePreference('homeHidden');
  const layout = resolveHomeLayout(session.data?.widgets ?? [], order, hidden);

  const move = (w: HomeWidget, delta: -1 | 1) => {
    const ids = layout.map((x) => x.widget);
    const i = ids.indexOf(w);
    const j = i + delta;
    if (i < 0 || j < 0 || j >= ids.length) return;
    [ids[i], ids[j]] = [ids[j] as HomeWidget, ids[i] as HomeWidget];
    setPreference('homeOrder', ids);
  };
  const toggle = (w: HomeWidget, visible: boolean) =>
    setPreference('homeHidden', visible ? hidden.filter((x) => x !== w) : [...new Set([...hidden, w])]);

  const preview = (
    <HeroCard>
      <View style={styles.rowBetween}>
        <Text variant="subhead" weight="600" style={styles.onHero}>
          {i18n.t('customize.preview')}
        </Text>
        <Icon name="palette" size={18} color="#FFFFFF" />
      </View>
      <Text variant="title" style={styles.onHero}>
        {i18n.t(`customize.accent.${accent}`)}
      </Text>
      <View style={[styles.row, { gap: t.space.sm }]}>
        <View style={[styles.previewChip, { backgroundColor: '#FFFFFF' }]}>
          <Icon name="check" size={14} color={t.colors.heroEnd} weight="bold" />
          <Text variant="footnote" weight="700" style={{ color: t.colors.heroEnd }}>
            {i18n.t('approvals.approve')}
          </Text>
        </View>
        <View style={[styles.previewChip, { backgroundColor: 'rgba(255,255,255,0.22)' }]}>
          <Text variant="footnote" weight="600" style={styles.onHero}>
            {i18n.t(`more.appearance.${appearance}`)} · {i18n.t(`customize.density.${density}`)}
          </Text>
        </View>
      </View>
    </HeroCard>
  );

  const theme = (
    <ListSection title={i18n.t('customize.theme')}>
      <Field label={i18n.t('more.appearance')}>
        <SegmentedControl
          segments={[
            { value: 'system', label: i18n.t('more.appearance.system') },
            { value: 'light', label: i18n.t('more.appearance.light') },
            { value: 'dark', label: i18n.t('more.appearance.dark') },
          ]}
          value={appearance}
          onChange={(v) => setPreference('appearance', v)}
        />
      </Field>
      <Field label={i18n.t('customize.accentColor')}>
        <View style={styles.swatches} accessibilityRole="radiogroup">
          {ACCENT_IDS.map((id) => (
            <Swatch key={id} id={id} selected={id === accent} label={i18n.t(`customize.accent.${id}`)} />
          ))}
        </View>
      </Field>
      <Field label={i18n.t('customize.density')}>
        <SegmentedControl
          segments={[
            { value: 'comfortable', label: i18n.t('customize.density.comfortable') },
            { value: 'compact', label: i18n.t('customize.density.compact') },
          ]}
          value={density}
          onChange={(v) => setPreference('density', v)}
        />
      </Field>
      <Field label={i18n.t('more.look')} last={!isDesktop}>
        <SegmentedControl
          segments={[
            { value: 'auto', label: i18n.t('more.look.auto') },
            { value: 'ios', label: 'iOS' },
            { value: 'android', label: 'Android' },
          ]}
          value={flavor}
          onChange={(v) => setPreference('flavor', v)}
        />
      </Field>
      {isDesktop && (
        <Field label={i18n.t('customize.sidebar')} last>
          <SegmentedControl
            segments={[
              { value: 'expanded', label: i18n.t('customize.sidebar.expanded') },
              { value: 'rail', label: i18n.t('customize.sidebar.rail') },
            ]}
            value={sidebar}
            onChange={(v) => setPreference('sidebar', v)}
          />
        </Field>
      )}
    </ListSection>
  );

  const home = (
    <ListSection title={i18n.t('customize.home')} footer={i18n.t('customize.homeFooter')}>
      {layout.map(({ widget, visible }, idx) => (
        <View
          key={widget}
          style={[
            styles.widgetRow,
            { paddingHorizontal: t.space.lg },
            idx < layout.length - 1 && { borderBottomWidth: StyleSheet.hairlineWidth, borderBottomColor: t.colors.separator },
          ]}
        >
          <Icon name={WIDGET_ICON[widget]} size={20} color={visible ? t.colors.primary : t.colors.textTertiary} />
          <Text variant="body" style={{ flex: 1 }} color={visible ? 'text' : 'textTertiary'} numberOfLines={1}>
            {i18n.t(`widget.${widget}`)}
          </Text>
          <ReorderButton icon="chevronUp" disabled={idx === 0} label={i18n.t('customize.moveUp', { name: i18n.t(`widget.${widget}`) })} onPress={() => move(widget, -1)} />
          <ReorderButton icon="chevronDown" disabled={idx === layout.length - 1} label={i18n.t('customize.moveDown', { name: i18n.t(`widget.${widget}`) })} onPress={() => move(widget, 1)} />
          <Toggle value={visible} onValueChange={(v) => toggle(widget, v)} label={i18n.t('customize.show', { name: i18n.t(`widget.${widget}`) })} />
        </View>
      ))}
    </ListSection>
  );

  return (
    <Screen maxWidth={1100}>
      {isDesktop ? (
        <View style={[styles.columns, { gap: t.space.xxl }]}>
          <View style={{ flex: 1, gap: t.space.xxl }}>
            {preview}
            {theme}
          </View>
          <View style={{ flex: 1, gap: t.space.xxl }}>{home}</View>
        </View>
      ) : (
        <>
          {preview}
          {theme}
          {home}
        </>
      )}
      <Card style={{ alignItems: 'center' }}>
        <Button title={i18n.t('customize.reset')} variant="plain" onPress={resetAppearance} />
      </Card>
    </Screen>
  );
}

function Field({ label, children, last = false }: { label: string; children: React.ReactNode; last?: boolean }) {
  const t = useTheme();
  return (
    <View style={{ padding: t.space.lg, gap: t.space.sm, borderBottomWidth: last ? 0 : StyleSheet.hairlineWidth, borderBottomColor: t.colors.separator }}>
      <Text variant="subhead" color="textSecondary">
        {label}
      </Text>
      {children}
    </View>
  );
}

function Swatch({ id, selected, label }: { id: AccentId; selected: boolean; label: string }) {
  const t = useTheme();
  const c = applyAccent(PALETTES[t.flavor][t.scheme], id, t.flavor, t.scheme);
  return (
    <Touchable
      onPress={() => setPreference('accent', id)}
      haptic="selection"
      feedback="none"
      accessibilityRole="radio"
      accessibilityState={{ selected }}
      accessibilityLabel={label}
      style={styles.swatchWrap}
    >
      <View style={[styles.swatchRing, { borderColor: selected ? c.primary : 'transparent' }]}>
        <View style={[styles.swatch, { backgroundColor: c.primary }]}>
          <View style={[styles.swatchHalf, { backgroundColor: c.heroEnd }]} />
          {selected && <Icon name="check" size={16} color={c.onPrimary} weight="bold" />}
        </View>
      </View>
      <Text variant="caption" color={selected ? 'text' : 'textSecondary'} weight={selected ? '600' : '400'} numberOfLines={1}>
        {label}
      </Text>
    </Touchable>
  );
}

function ReorderButton({ icon, onPress, disabled, label }: { icon: IconName; onPress: () => void; disabled: boolean; label: string }) {
  const t = useTheme();
  return (
    <Touchable onPress={onPress} disabled={disabled} feedback="highlight" haptic="selection" accessibilityLabel={label} style={[styles.reorder, { backgroundColor: t.colors.fill }]}>
      <Icon name={icon} size={14} color={t.colors.text} />
    </Touchable>
  );
}

const styles = StyleSheet.create({
  row: { flexDirection: 'row', alignItems: 'center' },
  rowBetween: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between' },
  onHero: { color: '#FFFFFF' },
  columns: { flexDirection: 'row', alignItems: 'flex-start' },
  swatches: { flexDirection: 'row', flexWrap: 'wrap', gap: 12 },
  swatchWrap: { alignItems: 'center', gap: 4, width: 64 },
  swatchRing: { padding: 3, borderRadius: 26, borderWidth: 2 },
  swatch: { width: 40, height: 40, borderRadius: 20, alignItems: 'center', justifyContent: 'center', overflow: 'hidden' },
  swatchHalf: { position: 'absolute', right: 0, bottom: 0, width: 20, height: 40, transform: [{ rotate: '45deg' }, { translateX: 8 }] },
  previewChip: { flexDirection: 'row', alignItems: 'center', gap: 6, paddingHorizontal: 14, paddingVertical: 8, borderRadius: 999 },
  widgetRow: { flexDirection: 'row', alignItems: 'center', gap: 10, minHeight: 56 },
  reorder: { width: 32, height: 32, borderRadius: 16, alignItems: 'center', justifyContent: 'center' },
});
