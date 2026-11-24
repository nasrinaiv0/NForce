import { useQuery } from '@tanstack/react-query';
import { useState } from 'react';
import { TextInput, View } from 'react-native';
import { Button } from '@/components/Button';
import { Card } from '@/components/Surface';
import { Text } from '@/components/Text';
import { formatPhpCents, parsePersonalPayrollDetail, type PersonalPayrollDetail } from '@/data/accountingReview';
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
  queryKey:['nforce','personal-payroll-detail-v1',user,org,period],enabled,retry:false,gcTime:0,staleTime:0,refetchInterval:15000,refetchOnMount:'always',
  queryFn:async () => {
   if (org === undefined || user === undefined) throw new Error('Personal payroll unavailable');
   const {data,error} = await supabase().rpc('payroll_self_detail',{p_organization_id:org,p_period_start:period});
   const current = backendStore.get();
   if (error !== null || current.auth !== 'signed_in' || current.userId !== user || activeWorkspace(current)?.organizationId !== org) throw new Error('Personal payroll unavailable');
   return parsePersonalPayrollDetail(data,org,user,period);
  },
 });
 const liveData = enabled && period === date && !q.isFetching && !q.isError ? q.data : undefined;
 const data = backend === 'demo' ? {grossCents:'3000000',sssEmployeeCents:'150000',philhealthEmployeeCents:'75000',pagibigEmployeeCents:'20000',employeeContributionCents:'245000',withholdingCents:'100755',netCents:'2654245'} : liveData?.summary;
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
   {data !== undefined && <PayrollEvidence detail={backend==='demo'?fictionalDetail:liveData} />}
 </Card>;
}

const fictionalDetail: Pick<PersonalPayrollDetail,'frequency'|'exemptCents'|'taxableCents'|'taxDeductibleCents'|'basicCents'|'premiumCents'|'items'|'paymentConfirmed'> = {
 frequency:'monthly',exemptCents:'0',taxableCents:'2755000',taxDeductibleCents:'245000',basicCents:'3000000',premiumCents:'0',paymentConfirmed:false,
 items:[{date:'2026-02-02',code:'REG',start:'2026-02-02T01:00:00Z',end:'2026-02-02T09:00:00Z',seconds:'28800',hourlyRate:'123.2876712328767123',multiplier:'1',recordedAmount:null,siteReference:'Fictional office',method:'monthly_increment'}],
};
const labels = {
 en:{heading:'Payslip detail',period:'Payroll frequency',payment:'Payment not confirmed',base:'Basic salary',premium:'Premium pay',exempt:'Tax-exempt earnings',deductible:'Tax-deductible contributions',taxable:'Taxable income',what:'What',when:'When',where:'Where',time:'Time',how:'How',amount:'Recorded amount (PHP, before period rounding)',unknown:'Not recorded',monthly_increment:'Hourly rate × hours × (multiplier − 1); basic salary accounted for separately',hourly_factor:'Hourly rate × hours × multiplier',salary_allocation:'Recorded salary allocation',recorded_benefit:'Recorded benefit',recorded_amount:'Recorded amount',period_total_only:'Included in period calculation; separate amount not recorded',show:'Show work and earnings evidence',hide:'Hide work and earnings evidence',notice:'Times are recorded instants, not necessarily a clock-in or clock-out. Worksite is the historical site reference, not GPS. No actual payment date or channel is recorded.',total:'Gross − employee contributions − withholding = net pay'},
 fil:{heading:'Detalye ng payslip',period:'Dalas ng payroll',payment:'Hindi kumpirmado ang bayad',base:'Batayang sahod',premium:'Premium pay',exempt:'Kita na walang buwis',deductible:'Kontribusyong bawas sa buwis',taxable:'Kita na may buwis',what:'Ano',when:'Kailan',where:'Saan',time:'Oras',how:'Paano',amount:'Naitalang halaga (PHP bago rounding)',unknown:'Walang tala',monthly_increment:'Hourly rate × oras × (multiplier − 1); hiwalay ang batayang sahod',hourly_factor:'Hourly rate × oras × multiplier',salary_allocation:'Naitalang hatian ng sahod',recorded_benefit:'Naitalang benepisyo',recorded_amount:'Naitalang halaga',period_total_only:'Kasama sa period; walang hiwalay na halaga',show:'Ipakita ang tala ng trabaho at kita',hide:'Itago ang tala',notice:'Mga naitalang oras at dating worksite reference, hindi GPS. Walang kumpirmadong petsa o paraan ng bayad.',total:'Gross − kontribusyon ng empleyado − withholding = net pay'},
 es:{heading:'Detalle de nómina',period:'Frecuencia de nómina',payment:'Pago no confirmado',base:'Salario base',premium:'Prima salarial',exempt:'Ingresos exentos',deductible:'Contribuciones deducibles',taxable:'Ingresos imponibles',what:'Qué',when:'Cuándo',where:'Dónde',time:'Tiempo',how:'Cómo',amount:'Importe registrado (PHP, antes del redondeo)',unknown:'No registrado',monthly_increment:'Tarifa × horas × (multiplicador − 1); salario base separado',hourly_factor:'Tarifa × horas × multiplicador',salary_allocation:'Asignación salarial registrada',recorded_benefit:'Prestación registrada',recorded_amount:'Importe registrado',period_total_only:'Incluido en el período; sin importe separado',show:'Mostrar trabajo e ingresos',hide:'Ocultar trabajo e ingresos',notice:'Instantes registrados y referencia histórica del lugar, no GPS. Sin fecha ni canal de pago confirmado.',total:'Bruto − contribuciones del empleado − retención = neto'},
} as const;
function PayrollEvidence({detail}:{detail:typeof fictionalDetail|undefined}) {
 const t=useTheme(),i18n=useI18n(),c=labels[i18n.locale];
 const [open,setOpen]=useState(false);
 if(!detail)return null;
 const row=(label:string,value:string)=><View key={label} style={{flexDirection:'row',justifyContent:'space-between',flexWrap:'wrap',gap:t.space.sm}}><Text variant="footnote" color="textSecondary">{label}</Text><Text variant="footnote" tabular>{value}</Text></View>;
 const decimal=(v:string|null)=>v===null?c.unknown:v;
 return <View style={{gap:t.space.md,borderTopWidth:1,borderTopColor:t.colors.separator,paddingTop:t.space.md}}>
  <Text variant="headline" accessibilityRole="header">{c.heading}</Text>
  <Text variant="footnote" color="textSecondary">{c.payment}</Text>
  {row(c.period,detail.frequency)}
  {[ [c.base,detail.basicCents],[c.premium,detail.premiumCents],[c.exempt,detail.exemptCents],[c.deductible,detail.taxDeductibleCents],[c.taxable,detail.taxableCents] ].map(([label,value])=>row(label??'',value==null?c.unknown:formatPhpCents(value)))}
  <Text variant="footnote" color="textSecondary">{c.total}</Text>
  <Button title={open?c.hide:c.show} variant="tonal" onPress={()=>setOpen(v=>!v)}/>
  {open&&<>
   <Text variant="footnote" color="textSecondary">{c.notice}</Text>
   {detail.items.map((item,index)=><View key={index} style={{gap:t.space.sm,borderTopWidth:1,borderTopColor:t.colors.separator,paddingTop:t.space.md}}>
    {row(c.what,item.code)}
    {row(c.when,item.date??c.unknown)}
    {row(c.where,item.siteReference??c.unknown)}
    {row(c.time,item.seconds===null?c.unknown:`${item.seconds} s`)}
    {item.start!==null&&row('Start (ISO)',item.start)}
    {item.end!==null&&row('End (ISO)',item.end)}
    {row(c.amount,decimal(item.recordedAmount))}
    <Text variant="footnote" weight="600">{c.how}</Text>
    <Text variant="footnote">{c[item.method]}</Text>
    {item.hourlyRate!==null&&row('PHP / h',item.hourlyRate)}
    {item.multiplier!==null&&row('×',item.multiplier)}
   </View>)}
  </>}
 </View>;
}

