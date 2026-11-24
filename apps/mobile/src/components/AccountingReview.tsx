import { addDays, formatDuration, localDateKey, type DateKey } from '@nforce/core';
import { useQuery } from '@tanstack/react-query';
import { useState } from 'react';
import { View } from 'react-native';

import { AccountingReleaseGate } from '@/components/AccountingReleaseGate';
import { Button } from '@/components/Button';
import { Card } from '@/components/Surface';
import { Text } from '@/components/Text';
import { parseAccountingSnapshot, type AccountingScope } from '@/data/accountingReview';
import { liveConfigured, supabase } from '@/data/supabase';
import { useTheme } from '@/design/theme';
import { useI18n } from '@/i18n';
import { activeWorkspace, backendStore, useBackend } from '@/state/backend';
import { usePreference } from '@/state/preferences';

const copy = {
  en: { title: 'Locked accounting review', hint: 'Original locked server records only. Adjustments, wage amounts, exports and submission are not included.', employees: 'Employees', worked: 'Worked time', overtime: 'Approved overtime', earlier: 'Previous week', later: 'Next week', waiting: 'Checking server records…', reload: 'Check again', source: 'Server-verified original snapshot' },
  fil: { title: 'Pagsusuri ng naka-lock na accounting', hint: 'Orihinal na naka-lock na rekord ng server lamang. Hindi kasama ang mga adjustment, sahod, pag-export at pagsusumite.', employees: 'Mga empleyado', worked: 'Oras ng trabaho', overtime: 'Aprubadong overtime', earlier: 'Nakaraang linggo', later: 'Susunod na linggo', waiting: 'Sinusuri ang mga rekord…', reload: 'Suriin muli', source: 'Orihinal na rekord mula sa server' },
  es: { title: 'Revisión contable bloqueada', hint: 'Solo registros originales bloqueados del servidor. No incluye ajustes, salarios, exportaciones ni envíos.', employees: 'Empleados', worked: 'Tiempo trabajado', overtime: 'Horas extra aprobadas', earlier: 'Semana anterior', later: 'Semana siguiente', waiting: 'Consultando registros…', reload: 'Consultar de nuevo', source: 'Registro original del servidor verificado' },
} as const;

function lastWeek(zone: string): DateKey {
  const today = localDateKey(new Date(), zone) as DateKey;
  const weekday = new Date(today + 'T12:00:00Z').getUTCDay();
  return addDays(today, -((weekday + 6) % 7) - 7);
}

export function AccountingReview({ scope, requestedUser }: { scope: AccountingScope; requestedUser?: string | undefined }) {
  const t = useTheme();
  const i18n = useI18n();
  const message = copy[i18n.locale];
  const state = useBackend((s) => s);
  const selected = usePreference('workspaceId');
  const workspace = state.workspaces?.find((w) => w.organizationId === selected) ?? state.workspaces?.[0];
  const organization = workspace?.organizationId;
  const user = state.userId;
  const [chosen, setChosen] = useState<DateKey | undefined>(undefined);
  const period = chosen ?? lastWeek(workspace?.timeZone ?? 'UTC');
  const enabled = liveConfigured && state.auth === 'signed_in' && user !== undefined && organization !== undefined && (scope !== 'self' || requestedUser === undefined || requestedUser === user);
  const q = useQuery({
    queryKey: ['nforce', 'locked-review-v3', user, organization, period, scope],
    enabled, retry: false, gcTime: 0, staleTime: 0, refetchOnMount: 'always', refetchInterval: 15000,
    queryFn: async () => {
      if (organization === undefined || user === undefined) throw new Error('Review unavailable');
      const { data, error } = await supabase().rpc('accounting_review_snapshot', { p_organization_id: organization, p_period_start: period, p_scope: scope });
      const current = backendStore.get();
      if (error !== null || current.auth !== 'signed_in' || current.userId !== user || activeWorkspace(current)?.organizationId !== organization) throw new Error('Review unavailable');
      return parseAccountingSnapshot(data, organization, period, scope);
    },
  });
  const snapshot = enabled && !q.isFetching && !q.isError ? q.data : undefined;
  return (
    <View style={{ gap: t.space.lg }}>
      <Card style={{ gap: t.space.md }}>
        <Text variant="headline" accessibilityRole="header">{message.title}</Text>
        <Text variant="footnote" color="textSecondary">{message.hint}</Text>
        <Text variant="body" weight="600" tabular>{i18n.date(period)} – {i18n.date(addDays(period, 6))}</Text>
        <View style={{ flexDirection: 'row', flexWrap: 'wrap', gap: t.space.sm }}>
          <Button title={message.earlier} size="small" variant="tonal" onPress={() => setChosen(addDays(period, -7))} />
          <Button title={message.later} size="small" variant="tonal" onPress={() => setChosen(addDays(period, 7))} />
        </View>
      </Card>
      {snapshot === undefined ? (
        <>
          <AccountingReleaseGate />
          {q.isFetching && <Text variant="footnote" color="textSecondary">{message.waiting}</Text>}
          {enabled && <Button title={message.reload} variant="tonal" onPress={() => { void q.refetch(); }} loading={q.isFetching} />}
        </>
      ) : (
        <Card style={{ gap: t.space.md }}>
          <Text variant="caption" color="textSecondary">{message.source}</Text>
          {scope === 'organization' && <Text variant="body">{message.employees}: {i18n.number(snapshot.employeeCount)}</Text>}
          <Text variant="body">{message.worked}: {formatDuration(snapshot.workedMinutes)}</Text>
          <Text variant="body">{message.overtime}: {formatDuration(snapshot.approvedOvertimeMinutes)}</Text>
          {snapshot.lines.map((line) => (
            <View key={line.code} style={{ flexDirection: 'row', justifyContent: 'space-between', gap: t.space.sm }}>
              <Text variant="body">{line.code}</Text>
              <Text variant="body" tabular>{formatDuration(line.minutes)}</Text>
            </View>
          ))}
        </Card>
      )}
    </View>
  );
}
