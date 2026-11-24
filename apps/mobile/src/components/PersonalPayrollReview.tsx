import { useQuery } from '@tanstack/react-query';
import { useState } from 'react';
import { TextInput, View } from 'react-native';
import { Button } from '@/components/Button';
import { Card } from '@/components/Surface';
import { Text } from '@/components/Text';
import { formatPhpCents, parsePersonalPayroll } from '@/data/accountingReview';
import { liveConfigured, supabase } from '@/data/supabase';
import { useTheme } from '@/design/theme';
import { useI18n } from '@/i18n';
import { activeWorkspace, backendStore, useBackend } from '@/state/backend';
import { usePreference } from '@/state/preferences';

const copy = {
 en: { title:'Personal payroll', hint:'Only your released payroll amounts and employee deductions. This is an accrual review, not proof of payment.', date:'Period start (YYYY-MM-DD)', check:'Check my payroll', unavailable:'No released personal payroll is available for this period.', gross:'Gross pay', sss:'My SSS', ph:'My PhilHealth', pi:'My Pag-IBIG', ee:'My total contributions', tax:'Withholding tax', net:'Net pay', demo:'Demo only — personal payroll is not published.' },
 fil: { title:'Personal na payroll', hint:'Ang iyong inilabas na halaga at kaltas lamang. Hindi ito patunay ng pagbabayad.', date:'Simula ng period (YYYY-MM-DD)', check:'Suriin ang payroll ko', unavailable:'Walang inilabas na personal na payroll para sa period na ito.', gross:'Kabuuang sahod', sss:'Aking SSS', ph:'Aking PhilHealth', pi:'Aking Pag-IBIG', ee:'Aking kabuuang kontribusyon', tax:'Withholding tax', net:'Netong sahod', demo:'Demo lamang — walang inilabas na personal na payroll.' },
 es: { title:'Nómina personal', hint:'Solo sus importes publicados y deducciones. No constituye prueba de pago.', date:'Inicio del período (YYYY-MM-DD)', check:'Consultar mi nómina', unavailable:'No hay nómina personal publicada para este período.', gross:'Salario bruto', sss:'Mi SSS', ph:'Mi PhilHealth', pi:'Mi Pag-IBIG', ee:'Mis contribuciones', tax:'Retención fiscal', net:'Salario neto', demo:'Solo demostración — nómina personal no publicada.' },
} as const;

export function PersonalPayrollReview() {
 const t = useTheme();
 const i18n = useI18n();
 const c = copy[i18n.locale];
 const backend = usePreference('backend');
 const selected = usePreference('workspaceId');
 const state = useBackend(s => s);
 const workspace = state.workspaces?.find(w => w.organizationId === selected) ?? state.workspaces?.[0];
 const org = workspace?.organizationId;
 const user = state.userId;
 const [date, setDate] = useState('');
 const [period, setPeriod] = useState('');
 const valid = /^\d{4}-\d{2}-\d{2}$/.test(date) && Number.isFinite(Date.parse(date+'T00:00:00Z')) && new Date(date+'T00:00:00Z').toISOString().slice(0,10) === date;
 const enabled = backend === 'live' && liveConfigured && state.auth === 'signed_in' && user !== undefined && org !== undefined && period !== '';
 const q = useQuery({
  queryKey:['nforce','personal-payroll-v1',user,org,period],enabled,retry:false,gcTime:0,staleTime:0,refetchInterval:15000,refetchOnMount:'always',
  queryFn:async () => {
   if (org === undefined || user === undefined) throw new Error('Personal payroll unavailable');
   const {data,error} = await supabase().rpc('payroll_self_snapshot',{p_organization_id:org,p_period_start:period});
   const current = backendStore.get();
   if (error !== null || current.auth !== 'signed_in' || current.userId !== user || activeWorkspace(current)?.organizationId !== org) throw new Error('Personal payroll unavailable');
   return parsePersonalPayroll(data,org,user,period);
  },
 });
 const liveData = enabled && period === date && !q.isFetching && !q.isError ? q.data : undefined;
 const data = backend === 'demo' ? {grossCents:'3000000',sssEmployeeCents:'150000',philhealthEmployeeCents:'75000',pagibigEmployeeCents:'20000',employeeContributionCents:'245000',withholdingCents:'100755',netCents:'2654245'} : liveData;
 return <Card style={{gap:t.space.md}}>
  <Text variant="headline" accessibilityRole="header">{c.title}</Text>
  <Text variant="footnote" color="textSecondary">{c.hint}</Text>
  {backend === 'demo' ? <Text variant="body">{c.demo}</Text> : <>
   <Text variant="footnote" color="textSecondary">{c.date}</Text>
   <TextInput accessibilityLabel={c.date} value={date} onChangeText={setDate} placeholder="2026-02-01" maxLength={10} autoCapitalize="none" style={{color:t.colors.text,backgroundColor:t.colors.fill,borderRadius:8,padding:12,minHeight:44}}/>
   <Button title={c.check} disabled={!valid || org === undefined || user === undefined} loading={q.isFetching} onPress={()=>{if(period===date) void q.refetch();else setPeriod(date);}}/>
  </>}
   {data === undefined ? <Text variant="footnote" color="textSecondary">{c.unavailable}</Text> :
    <View style={{gap:t.space.sm}}>
      {[[c.gross,data.grossCents],[c.sss,data.sssEmployeeCents],[c.ph,data.philhealthEmployeeCents],[c.pi,data.pagibigEmployeeCents],[c.ee,data.employeeContributionCents],[c.tax,data.withholdingCents],[c.net,data.netCents]].map(([label,value])=>
       <View key={label} style={{flexDirection:'row',justifyContent:'space-between',flexWrap:'wrap',gap:t.space.sm}}>
        <Text variant="body">{label}</Text><Text variant="body" tabular weight="600">{formatPhpCents(value ?? '0')}</Text>
       </View>)}
    </View>}
 </Card>;
}
