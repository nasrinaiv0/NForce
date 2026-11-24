import { View } from 'react-native';

import { Icon } from '@/components/Icon';
import { Card } from '@/components/Surface';
import { Text } from '@/components/Text';
import { useTheme } from '@/design/theme';
import { useI18n } from '@/i18n';

const copy = {
  en: { title: 'Accounting review required', body: 'Live payroll and timesheet results are unavailable until historical records, server calculations and independent review are verified. Payroll export and submission remain disabled.', note: 'Demo mode remains available for fictional data.' },
  fil: { title: 'Kailangan ang pagsusuri sa accounting', body: 'Hindi pa magagamit ang live na payroll at timesheet hanggang mapatunayan ang mga historikal na rekord, kalkulasyon ng server at independiyenteng pagsusuri. Hindi pa pinapayagan ang pag-export o pagsusumite.', note: 'Magagamit pa rin ang demo mode para sa kathang-isip na datos.' },
  es: { title: 'Revisión contable necesaria', body: 'La nómina y las hojas de horas reales no están disponibles hasta verificar los registros históricos, los cálculos del servidor y la revisión independiente. No se permite exportar ni enviar datos de nómina.', note: 'El modo de demostración sigue disponible con datos ficticios.' },
} as const;

export function AccountingReleaseGate() {
  const t = useTheme();
  const { locale } = useI18n();
  const message = copy[locale];
  return (
    <Card style={{ gap: t.space.md }}>
      <View style={{ flexDirection: 'row', alignItems: 'center', gap: t.space.sm }}>
        <Icon name="lock" size={22} color={t.colors.warning} />
        <Text variant="headline" style={{ flex: 1 }} accessibilityRole="header">{message.title}</Text>
      </View>
      <Text variant="body" color="textSecondary">{message.body}</Text>
      <Text variant="footnote" color="textSecondary">{message.note}</Text>
    </Card>
  );
}
