import { DEAL_STAGES, STAGE_PROBABILITY, pipelineSummary, type Deal } from '@nforce/core';
import { useMemo } from 'react';
import { ScrollView, StyleSheet, View } from 'react-native';

import { KpiTile } from '@/components/Charts';
import { ListControls, useListView } from '@/components/ListView';
import { Pill, type Tone } from '@/components/Display';
import { ErrorState, LoadingBlock, Screen } from '@/components/Screen';
import { Card } from '@/components/Surface';
import { Text } from '@/components/Text';
import { dealFields } from '@/data/listFields';
import { errorMessage, useDeals } from '@/data/queries';
import { useTheme } from '@/design/theme';
import { useResponsive } from '@/hooks/useResponsive';
import { useI18n, type I18n } from '@/i18n';

const STAGE_TONE: Readonly<Record<Deal['stage'], Tone>> = { lead: 'neutral', qualified: 'info', proposal: 'primary', negotiation: 'warning', won: 'success', lost: 'danger' };

/** CRM pipeline: forecast KPIs and a stage board (money in minor units). */
export default function CrmScreen() {
  const t = useTheme();
  const i18n = useI18n();
  const { isDesktop } = useResponsive();
  const deals = useDeals();
  const list = useListView({
    id: 'crm',
    fields: useMemo(() => dealFields(i18n), [i18n]),
    defaultSort: { key: 'close', direction: 'asc' },
    searchText: (d) => [d.name, d.account, d.ownerName],
    quickFilters: [
      { value: 'all', label: i18n.t('list.all') },
      { value: 'open', label: i18n.t('crm.open'), test: (d: Deal) => d.stage !== 'won' && d.stage !== 'lost' },
      { value: 'won', label: i18n.t('crm.stage.won'), test: (d: Deal) => d.stage === 'won' },
      { value: 'lost', label: i18n.t('crm.stage.lost'), test: (d: Deal) => d.stage === 'lost' },
    ],
  });
  const shown = list.apply(deals.data ?? []);
  // KPIs follow the filters, so a filtered view shows its own forecast.
  const summary = pipelineSummary(shown);
  if (deals.isError) {
    return (
      <Screen>
        <ErrorState onRetry={() => void deals.refetch()} message={errorMessage(deals.error, i18n.t('common.errorBody'))} />
      </Screen>
    );
  }
  if (deals.data === undefined) {
    return (
      <Screen>
        <LoadingBlock rows={4} height={90} />
      </Screen>
    );
  }
  const money = (minor: number) => formatMoney(i18n, minor, deals.data?.[0]?.currency ?? 'PHP');
  const board = DEAL_STAGES.map((stage) => ({ stage, deals: shown.filter((d) => d.stage === stage) })).filter((b) => b.deals.length > 0 || list.activeCount === 0);
  const column = (stage: Deal['stage'], list: Deal[]) => (
    <View key={stage} style={[styles.column, { gap: t.space.sm, width: isDesktop ? undefined : 260, flex: isDesktop ? 1 : undefined }]}>
      <View style={styles.rowBetween}>
        <Pill label={i18n.t(`crm.stage.${stage}`)} tone={STAGE_TONE[stage]} />
        <Text variant="caption" color="textSecondary">
          {list.length} · {Math.round(STAGE_PROBABILITY[stage] * 100)}%
        </Text>
      </View>
      {list.map((d) => (
        <Card key={d.id} style={{ gap: 4 }} accessibilityLabel={`${d.name}, ${d.account}, ${money(d.amountMinor)}`}>
          <Text variant="subhead" weight="600" numberOfLines={2}>
            {d.name}
          </Text>
          <Text variant="footnote" color="textSecondary" numberOfLines={1}>
            {d.account}
          </Text>
          <Text variant="headline" tabular>
            {money(d.amountMinor)}
          </Text>
          <Text variant="caption" color="textTertiary">
            {d.ownerName} · {i18n.date(d.closeDate as never, { month: 'short', day: 'numeric' })}
          </Text>
        </Card>
      ))}
    </View>
  );
  return (
    <Screen onRefresh={() => deals.refetch()} maxWidth={1500}>
      <View style={[styles.kpis, { gap: t.space.md }]}>
        <KpiTile label={i18n.t('crm.open')} value={money(summary.openAmountMinor)} />
        <KpiTile label={i18n.t('crm.forecast')} value={money(summary.weightedForecastMinor)} hint={i18n.t('crm.forecastHint')} />
        <KpiTile label={i18n.t('crm.won')} value={money(summary.wonAmountMinor)} />
        <KpiTile label={i18n.t('crm.winRate')} value={i18n.number(summary.winRate, { style: 'percent' })} />
      </View>
      <ListControls state={list} searchPlaceholder={i18n.t('list.search')} resultCount={shown.length} />
      <Text variant="footnote" color="textSecondary">
        {i18n.t('crm.readOnly')}
      </Text>
      {isDesktop ? (
        <View style={[styles.board, { gap: t.space.md }]}>{board.map((b) => column(b.stage, b.deals))}</View>
      ) : (
        <ScrollView horizontal showsHorizontalScrollIndicator={false} contentContainerStyle={{ gap: t.space.md }}>
          {board.map((b) => column(b.stage, b.deals))}
        </ScrollView>
      )}
    </Screen>
  );
}

function formatMoney(i18n: I18n, minor: number, currency: string): string {
  const major = minor / 100;
  return new Intl.NumberFormat(i18n.tag, { style: 'currency', currency, notation: major >= 1_000_000 ? 'compact' : 'standard', maximumFractionDigits: major >= 1_000_000 ? 1 : 0 }).format(major);
}

const styles = StyleSheet.create({
  kpis: { flexDirection: 'row', flexWrap: 'wrap' },
  board: { flexDirection: 'row', alignItems: 'flex-start' },
  column: {},
  rowBetween: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between' },
});
