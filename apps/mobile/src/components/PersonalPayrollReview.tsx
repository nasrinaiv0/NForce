import { useQuery } from '@tanstack/react-query';
import { useState, type ReactNode } from 'react';
import { useSession } from '@/data/queries';
import { TextInput, View } from 'react-native';
import { Button } from '@/components/Button';
import { Card } from '@/components/Surface';
import { Text } from '@/components/Text';
import { formatPhpCents, formatPayslipDecimal, formatPayslipInstant, parsePersonalPayrollDetail, type PersonalPayrollDetail } from '@/data/accountingReview';
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
 const session = useSession();
 const persona = usePreference('persona');
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
 const detail=backend==='demo'?fictionalDetail:liveData;
 const identity=session.data;
 const identityValid=identity!==undefined&&(backend==='demo'?identity.role===persona:state.auth==='signed_in'&&identity.user.id===user&&identity.organization.id===org);
 const v=modern[i18n.locale];
 return <View style={{gap:t.space.lg}}>
  <View style={{gap:t.space.xs,paddingHorizontal:t.space.xs}}>
   <Text variant="headline" accessibilityRole="header">{c.title}</Text>
   {identityValid&&identity!==undefined&&<><Text variant="title2" weight="700">{identity.user.name}</Text><Text variant="subhead" color="textSecondary">{identity.organization.name}</Text></>}
   <Text variant="footnote" color="textSecondary">{backend==='demo'?c.demo:c.hint}</Text>
  </View>
  {backend!=='demo'&&<Card style={{gap:t.space.sm}}>
   <Text variant="footnote" color="textSecondary">{c.date}</Text>
   <TextInput accessibilityLabel={c.date} value={date} onChangeText={setDate} placeholder="2026-02-01" maxLength={10} autoCapitalize="none" style={{color:t.colors.text,backgroundColor:t.colors.fill,borderRadius:12,padding:12,minHeight:44}}/>
   <Button title={c.check} disabled={!valid || org === undefined || user === undefined} loading={q.isFetching} onPress={()=>{if(period===date) void q.refetch();else setPeriod(date);}}/>
  </Card>}
  {data===undefined?<Card><Text variant="footnote" color="textSecondary">{c.unavailable}</Text></Card>:<>
   <Card style={{backgroundColor:t.colors.primaryContainer,gap:t.space.md,padding:t.space.xl}}>
    <View style={{gap:t.space.xs}}>
     <Text variant="label" color="onPrimaryContainer">{c.net}</Text>
     <Text variant="largeTitle" weight="700" color="onPrimaryContainer" tabular style={{flexShrink:1}}>{formatPhpCents(data.netCents)}</Text>
     <Text variant="footnote" color="onPrimaryContainer">{backend==='demo'?'2026-02-01 – 2026-02-28':liveData?.summary.periodStart+' – '+liveData?.summary.periodEnd}</Text>
     <Text variant="footnote" color="onPrimaryContainer">{labels[i18n.locale].payment}</Text>
    </View>
    <View style={{flexDirection:'row',height:8,borderRadius:8,overflow:'hidden',backgroundColor:t.colors.fill}}>
     <View style={{flex:Number(BigInt(data.netCents)),backgroundColor:t.colors.primary}}/>
     <View style={{flex:Number(BigInt(data.employeeContributionCents)+BigInt(data.withholdingCents)),backgroundColor:t.colors.outline}}/>
    </View>
    <View style={{flexDirection:'row',flexWrap:'wrap',gap:t.space.lg}}>
     <View style={{flexGrow:1,gap:t.space.xs}}><Text variant="footnote" color="onPrimaryContainer">{c.gross}</Text><Text variant="headline" color="onPrimaryContainer" tabular>{formatPhpCents(data.grossCents)}</Text></View>
     <View style={{flexGrow:1,gap:t.space.xs}}><Text variant="footnote" color="onPrimaryContainer">{v.totalDeductions}</Text><Text variant="headline" color="onPrimaryContainer" tabular>{formatPhpCents((BigInt(data.employeeContributionCents)+BigInt(data.withholdingCents)).toString())}</Text></View>
    </View>
   </Card>
   <PayrollEvidence detail={detail} grossCents={data.grossCents} periodStart={backend==='demo'?'2026-02-01':liveData?.summary.periodStart} periodEnd={backend==='demo'?'2026-02-28':liveData?.summary.periodEnd} revision={backend==='demo'?1:liveData?.summary.revision} deductions={<Card style={{gap:t.space.md}}>
    <Text variant="headline" accessibilityRole="header">{v.deductions}</Text>
    <PayslipRow label={c.sss} value={formatPhpCents(data.sssEmployeeCents)}/>
    {detail?.sssRegularCents !== null && detail?.sssRegularCents !== undefined&&detail.sssMpfCents !== null && detail.sssMpfCents !== undefined&&<View style={{padding:t.space.md,backgroundColor:t.colors.fill,borderRadius:t.shape.control,gap:t.space.sm}}>
     <PayslipRow label={v.sssRegular} value={formatPhpCents(detail.sssRegularCents)}/>
     <PayslipRow label={v.sssMpf} value={formatPhpCents(detail.sssMpfCents)}/>
    </View>}
    <PayslipRow label={c.ph} value={formatPhpCents(data.philhealthEmployeeCents)}/>
    <PayslipRow label={c.pi} value={formatPhpCents(data.pagibigEmployeeCents)}/>
    <PayslipRow label={c.ee} value={formatPhpCents(data.employeeContributionCents)}/>
    <PayslipRow label={c.tax} value={formatPhpCents(data.withholdingCents)}/>
    <View style={{borderTopWidth:t.shape.hairline,borderTopColor:t.colors.separator,paddingTop:t.space.md}}><PayslipRow label={v.totalDeductions} value={formatPhpCents((BigInt(data.employeeContributionCents)+BigInt(data.withholdingCents)).toString())}/></View>
   </Card>}/>
  </>}
 </View>;
}


const fictionalDetail: Pick<PersonalPayrollDetail,'frequency'|'exemptCents'|'taxableCents'|'taxDeductibleCents'|'basicCents'|'premiumCents'|'items'|'paymentConfirmed'|'releasedAt'|'sssRegularCents'|'sssMpfCents'> = {
 frequency:'monthly',exemptCents:'0',taxableCents:'2755000',taxDeductibleCents:'245000',basicCents:'2800000',premiumCents:'28767',paymentConfirmed:false,releasedAt:null,sssRegularCents:'100000',sssMpfCents:'50000',
 items:[
  {date:'2026-02-02',code:'REG',start:'2026-02-02T01:00:00Z',end:'2026-02-02T09:00:00Z',seconds:'28800',hourlyRate:'115.0684931506849315',multiplier:'1',recordedAmount:null,calculatedAmount:'0',siteReference:'Fictional office',method:'monthly_increment'},
  {date:'2026-02-02',code:'REG_OT',start:'2026-02-02T09:00:00Z',end:'2026-02-02T11:00:00Z',seconds:'7200',hourlyRate:'115.0684931506849315',multiplier:'1.25',recordedAmount:null,calculatedAmount:'287.67123287671232875',siteReference:'Fictional office',method:'hourly_factor'},
  {date:null,code:'taxable_allowance',start:null,end:null,seconds:null,hourlyRate:null,multiplier:null,recordedAmount:'1712.33',siteReference:null,method:'recorded_amount'}
 ],
};
const labels = {
 en:{heading:'Payslip detail',period:'Payroll frequency',payment:'Payment not confirmed',base:'Basic salary',premium:'Premium pay',exempt:'Tax-exempt earnings',deductible:'Tax-deductible contributions',taxable:'Taxable income',what:'What',when:'When',where:'Where',time:'Time',how:'How',amount:'Recorded amount (PHP, before period rounding)',unknown:'Not recorded',monthly_increment:'Hourly rate × hours × (multiplier − 1); basic salary accounted for separately',hourly_factor:'Hourly rate × hours × multiplier',salary_allocation:'Recorded salary allocation',recorded_benefit:'Recorded benefit',recorded_amount:'Recorded amount',period_total_only:'Included in period calculation; separate amount not recorded',show:'Show work and earnings evidence',hide:'Hide work and earnings evidence',notice:'Times are recorded instants, not necessarily a clock-in or clock-out. Worksite is the historical site reference, not GPS. No actual payment date or channel is recorded.',total:'Gross − employee contributions − withholding = net pay'},
 fil:{heading:'Detalye ng payslip',period:'Dalas ng payroll',payment:'Hindi kumpirmado ang bayad',base:'Batayang sahod',premium:'Premium pay',exempt:'Kita na walang buwis',deductible:'Kontribusyong bawas sa buwis',taxable:'Kita na may buwis',what:'Ano',when:'Kailan',where:'Saan',time:'Oras',how:'Paano',amount:'Naitalang halaga (PHP bago rounding)',unknown:'Walang tala',monthly_increment:'Hourly rate × oras × (multiplier − 1); hiwalay ang batayang sahod',hourly_factor:'Hourly rate × oras × multiplier',salary_allocation:'Naitalang hatian ng sahod',recorded_benefit:'Naitalang benepisyo',recorded_amount:'Naitalang halaga',period_total_only:'Kasama sa period; walang hiwalay na halaga',show:'Ipakita ang tala ng trabaho at kita',hide:'Itago ang tala',notice:'Mga naitalang oras at dating worksite reference, hindi GPS. Walang kumpirmadong petsa o paraan ng bayad.',total:'Gross − kontribusyon ng empleyado − withholding = net pay'},
 es:{heading:'Detalle de nómina',period:'Frecuencia de nómina',payment:'Pago no confirmado',base:'Salario base',premium:'Prima salarial',exempt:'Ingresos exentos',deductible:'Contribuciones deducibles',taxable:'Ingresos imponibles',what:'Qué',when:'Cuándo',where:'Dónde',time:'Tiempo',how:'Cómo',amount:'Importe registrado (PHP, antes del redondeo)',unknown:'No registrado',monthly_increment:'Tarifa × horas × (multiplicador − 1); salario base separado',hourly_factor:'Tarifa × horas × multiplicador',salary_allocation:'Asignación salarial registrada',recorded_benefit:'Prestación registrada',recorded_amount:'Importe registrado',period_total_only:'Incluido en el período; sin importe separado',show:'Mostrar trabajo e ingresos',hide:'Ocultar trabajo e ingresos',notice:'Instantes registrados y referencia histórica del lugar, no GPS. Sin fecha ni canal de pago confirmado.',total:'Bruto − contribuciones del empleado − retención = neto'},
} as const;
const modern={
 en:{deductions:'Deductions',totalDeductions:'Total deductions',sssRegular:'SSS regular · employee',sssMpf:'SSS provident fund · employee',earnings:'Earnings',taxableEarnings:'Taxable earnings before deductions',nonTaxable:'Non-taxable earnings',other:'Other earnings · reconciled remainder',released:'Released at',revision:'Revision',paymentDate:'Actual payout date',recorded:'Recorded line amount',calculated:'Calculated line amount',included:'Included in basic salary',exact:'Exact amount before period rounding',start:'Start · PHT',end:'End · PHT',showMore:'Show more records',sample:'Sample evidence only',rate:'Hourly rate',factor:'Pay multiplier',frequency:{daily:'Daily',weekly:'Weekly','semi-monthly':'Semi-monthly',monthly:'Monthly'},codes:{REG:'Regular work',RD:'Rest day',SH:'Special holiday',SH_RD:'Special holiday / rest day',RH:'Regular holiday',RH_RD:'Regular holiday / rest day',DH:'Double holiday',DH_RD:'Double holiday / rest day',guaranteed_salary:'Guaranteed salary',paid_leave:'Paid leave',paid_regular_holiday:'Paid regular holiday',unpaid_nonwork:'Unpaid non-work',monthly_covered:'Covered by monthly salary',maternity_covered:'Maternity-covered day',commission:'Commission',taxable_allowance:'Taxable allowance',other_taxable:'Other taxable earnings',benefit:'Benefit',other_recorded:'Other recorded item'},ot:'Overtime',nd:'Night differential'},
 fil:{deductions:'Mga kaltas',totalDeductions:'Kabuuang kaltas',sssRegular:'Regular na SSS · empleyado',sssMpf:'SSS provident fund · empleyado',earnings:'Mga kita',taxableEarnings:'Kita na may buwis bago kaltas',nonTaxable:'Kita na walang buwis',other:'Iba pang kita · natitirang halaga',released:'Inilabas noong',revision:'Bersyon',paymentDate:'Aktuwal na petsa ng bayad',recorded:'Naitalang halaga',calculated:'Kinalkulang halaga',included:'Kasama sa batayang sahod',exact:'Eksaktong halaga bago rounding',start:'Simula · PHT',end:'Wakas · PHT',showMore:'Ipakita ang iba pa',sample:'Halimbawa lamang',rate:'Sahod kada oras',factor:'Multiplier',frequency:{daily:'Arawan',weekly:'Lingguhan','semi-monthly':'Dalawang beses kada buwan',monthly:'Buwanan'},codes:{REG:'Regular na trabaho',RD:'Araw ng pahinga',SH:'Special holiday',SH_RD:'Special holiday / pahinga',RH:'Regular holiday',RH_RD:'Regular holiday / pahinga',DH:'Double holiday',DH_RD:'Double holiday / pahinga',guaranteed_salary:'Garantisadong sahod',paid_leave:'Bayad na leave',paid_regular_holiday:'Bayad na regular holiday',unpaid_nonwork:'Walang bayad',monthly_covered:'Kasama sa buwanang sahod',maternity_covered:'Araw ng maternity',commission:'Komisyon',taxable_allowance:'Allowance na may buwis',other_taxable:'Iba pang kita na may buwis',benefit:'Benepisyo',other_recorded:'Iba pang tala'},ot:'Overtime',nd:'Night differential'},
 es:{deductions:'Deducciones',totalDeductions:'Deducciones totales',sssRegular:'SSS regular · empleado',sssMpf:'Fondo de previsión SSS · empleado',earnings:'Ingresos',taxableEarnings:'Ingresos gravables antes de deducciones',nonTaxable:'Ingresos exentos',other:'Otros ingresos · saldo conciliado',released:'Publicado el',revision:'Revisión',paymentDate:'Fecha efectiva de pago',recorded:'Importe registrado',calculated:'Importe calculado',included:'Incluido en salario base',exact:'Importe exacto antes del redondeo',start:'Inicio · PHT',end:'Fin · PHT',showMore:'Mostrar más registros',sample:'Solo ejemplo',rate:'Tarifa por hora',factor:'Multiplicador',frequency:{daily:'Diaria',weekly:'Semanal','semi-monthly':'Quincenal',monthly:'Mensual'},codes:{REG:'Trabajo regular',RD:'Día de descanso',SH:'Festivo especial',SH_RD:'Festivo especial / descanso',RH:'Festivo regular',RH_RD:'Festivo regular / descanso',DH:'Festivo doble',DH_RD:'Festivo doble / descanso',guaranteed_salary:'Salario garantizado',paid_leave:'Permiso remunerado',paid_regular_holiday:'Festivo regular remunerado',unpaid_nonwork:'No trabajado sin pago',monthly_covered:'Incluido en salario mensual',maternity_covered:'Día de maternidad',commission:'Comisión',taxable_allowance:'Asignación imponible',other_taxable:'Otros ingresos imponibles',benefit:'Prestación',other_recorded:'Otro registro'},ot:'Horas extra',nd:'Plus nocturno'},
} as const;

function PayslipRow({label,value}:{label:string;value:string}) {
 const t=useTheme();
 return <View style={{flexDirection:'row',justifyContent:'space-between',alignItems:'baseline',flexWrap:'wrap',gap:t.space.sm}}>
  <Text variant="footnote" color="textSecondary" style={{flexShrink:1,maxWidth:'100%'}}>{label}</Text>
  <Text variant="subhead" weight="600" tabular style={{flexShrink:1,maxWidth:'100%'}}>{value}</Text>
 </View>;
}
function PayrollEvidence({detail,grossCents,periodStart,periodEnd,revision,deductions}:{detail:typeof fictionalDetail|undefined;grossCents:string;periodStart:string|undefined;periodEnd:string|undefined;revision:number|undefined;deductions:ReactNode}) {
 const t=useTheme(),i18n=useI18n(),c=labels[i18n.locale],v=modern[i18n.locale];
 const [open,setOpen]=useState(false);
 const [limit,setLimit]=useState(12);
 if(!detail)return null;
 const row=(label:string,value:string)=><PayslipRow key={label} label={label} value={value}/>;
 const money=(x:string|null|undefined)=>(x === null || x === undefined)?c.unknown:formatPhpCents(x);
 const remaining=detail.basicCents !== null && detail.basicCents !== undefined&&detail.premiumCents !== null && detail.premiumCents !== undefined?BigInt(grossCents)-BigInt(detail.basicCents)-BigInt(detail.premiumCents):null;
 const instant=(x:string|null|undefined)=>x==null?c.unknown:formatPayslipInstant(x,i18n.locale)??c.unknown;
 const description=(code:string)=>{
  const root=code.replace(/_ND$/,'').replace(/_OT$/,'');
  const name=(v.codes as Readonly<Record<string,string>>)[root]??root;
  return [name,code.includes('_OT')?v.ot:null,code.endsWith('_ND')?v.nd:null].filter(Boolean).join(' · ');
 };
 return <View style={{gap:t.space.lg}}>
  <Card style={{gap:t.space.md}}>
   <Text variant="headline" accessibilityRole="header">{c.heading}</Text>
   {row(c.when,periodStart!==undefined&&periodEnd!==undefined?periodStart+' – '+periodEnd:c.unknown)}
   {row(c.period,v.frequency[detail.frequency])}
   {row(v.revision,revision?.toString()??c.unknown)}
   {row(v.released,instant(detail.releasedAt))}
   {row(v.paymentDate,c.unknown)}
   <Text variant="footnote" color="textSecondary">{c.payment}</Text>
  </Card>
  <Card style={{gap:t.space.md}}>
   <Text variant="headline" accessibilityRole="header">{v.earnings}</Text>
   {row(c.base,money(detail.basicCents))}
   {row(c.premium,money(detail.premiumCents))}
   {remaining!==null&&remaining>=0n&&row(v.other,formatPhpCents(remaining.toString()))}
   <View style={{borderTopWidth:t.shape.hairline,borderTopColor:t.colors.separator,paddingTop:t.space.md,gap:t.space.md}}>
    {row(v.taxableEarnings,formatPhpCents((BigInt(grossCents)-BigInt(detail.exemptCents)).toString()))}
    {row(v.nonTaxable,money(detail.exemptCents))}
    {row(c.deductible,money(detail.taxDeductibleCents))}
    {row(c.taxable,money(detail.taxableCents))}
   </View>
   <Text variant="footnote" color="textSecondary">{c.total}</Text>
  </Card>
  {deductions}
  <Card style={{gap:t.space.md}}>
   <Button title={open?c.hide:c.show} variant="tonal" onPress={()=>setOpen(x=>!x)}/>
   {open&&<>
    <Text variant="footnote" color="textSecondary">{c.notice}</Text>
    {detail===fictionalDetail&&<Text variant="footnote" color="textSecondary">{v.sample}</Text>}
    {detail.items.slice(0,limit).map((item,index)=>{
     const amount=item.recordedAmount??item.calculatedAmount;
     return <View key={index} style={{gap:t.space.md,padding:t.space.md,backgroundColor:t.colors.fill,borderRadius:t.shape.control}}>
      <View style={{gap:t.space.xs}}>
       <Text variant="caption" color="textSecondary">{c.what} · {item.code}</Text>
       <Text variant="headline" weight="700">{description(item.code)}</Text>
       <Text variant="title2" tabular color="primary">{(amount === null || amount === undefined)?c.unknown:formatPayslipDecimal(amount)}</Text>
       <Text variant="caption" color="textSecondary">{(amount === null || amount === undefined)?c.unknown:item.recordedAmount !== null?v.recorded:v.calculated}{(amount !== null && amount !== undefined)?' · '+v.exact:''}</Text>
      </View>
      {row(c.when,item.date??c.unknown)}
      {row(c.where,item.siteReference??c.unknown)}
      {row(c.time,item.seconds===null?c.unknown:`${Math.floor(Number(item.seconds)/3600)}h ${Math.floor(Number(item.seconds)%3600/60)}m (${item.seconds} s)`)}
      {row(v.start,instant(item.start))}
      {row(v.end,instant(item.end))}
      <View style={{borderTopWidth:t.shape.hairline,borderTopColor:t.colors.separator,paddingTop:t.space.sm,gap:t.space.sm}}>
       <Text variant="footnote" weight="600">{c.how}</Text>
       <Text variant="footnote">{c[item.method]}</Text>
       {item.method==='monthly_increment'&&amount!==null&&amount!==undefined&&Number(amount)===0&&<Text variant="footnote" color="textSecondary">{v.included}</Text>}
       {item.hourlyRate!==null&&row(v.rate,formatPayslipDecimal(item.hourlyRate)+' / h')}
       {item.multiplier!==null&&row(v.factor,item.multiplier+'×')}
       {(amount !== null && amount !== undefined)&&row(v.exact,amount+' PHP')}
      </View>
     </View>;
    })}
    {limit<detail.items.length&&<Button title={v.showMore} variant="plain" onPress={()=>setLimit(x=>x+12)}/>}
   </>}
  </Card>
 </View>;
}
