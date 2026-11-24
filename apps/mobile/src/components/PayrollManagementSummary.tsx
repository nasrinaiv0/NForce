import { View } from 'react-native';
import { Card } from '@/components/Surface';
import { Text } from '@/components/Text';
import { useTheme } from '@/design/theme';
import { useI18n } from '@/i18n';
import { formatPhpCents, type MonetarySnapshot } from '@/data/accountingReview';

const copy = {
  en: {title:'Monetary payroll review',note:'Original posted accruals only. No payment, adjusted settlement or filing.',unavailable:'No authorized monetary review available.',labels:['Gross compensation','Employee contributions','Withholding','Net compensation','Employer contributions','Employer cost']},
  fil: {title:'Pagsusuri ng halaga ng payroll',note:'Orihinal na accounting accrual lamang. Walang pagbabayad o pagsusumite.',unavailable:'Walang awtorisadong pagsusuri ng halaga.',labels:['Kabuuang sahod','Kontribusyon ng empleyado','Withholding','Netong sahod','Kontribusyon ng employer','Gastos ng employer']},
  es: {title:'Revisión monetaria de nómina',note:'Solo devengos originales registrados. Sin pago, liquidación ajustada ni presentación.',unavailable:'No hay revisión monetaria autorizada.',labels:['Compensación bruta','Aportes del empleado','Retención','Compensación neta','Aportes del empleador','Costo del empleador']},
} as const;

export function PayrollManagementSummary({snapshot, fictional = false}: {snapshot?: MonetarySnapshot | undefined; fictional?: boolean}) {
  const t = useTheme();
  const {locale} = useI18n();
  const c = copy[locale];
  const values = snapshot === undefined ? [] : [snapshot.grossCents,snapshot.employeeContributionCents,snapshot.withholdingCents,snapshot.netCents,snapshot.employerContributionCents,snapshot.employerCostCents];
  return <Card style={{gap:t.space.md}}>
    <Text variant="headline" accessibilityRole="header">{c.title}</Text>
    <Text variant="footnote" color="textSecondary">{fictional ? (locale === 'fil' ? 'Halimbawa lamang — kathang-isip na halaga, hindi aktuwal na payroll.' : locale === 'es' ? 'Ejemplo ficticio: no es una nómina real.' : 'Fictional example only — not real payroll.') : c.note}</Text>
    {snapshot === undefined ? <Text variant="body" color="textSecondary">{c.unavailable}</Text> :
      values.map((value,i) => <View key={c.labels[i]} style={{flexDirection:'row',flexWrap:'wrap',justifyContent:'space-between',gap:t.space.sm}}>
        <Text variant="body" style={{flexShrink:1}}>{c.labels[i]}</Text>
        <Text variant="body" weight="600" tabular>{formatPhpCents(value)}</Text>
      </View>)}
  </Card>;
}
