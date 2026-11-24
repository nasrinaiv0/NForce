import { useQuery } from '@tanstack/react-query';
import { useState } from 'react';
import { TextInput, View } from 'react-native';
import { Button } from '@/components/Button';
import { Card } from '@/components/Surface';
import { Text } from '@/components/Text';
import { decisionResponse, parseDisputeReview, parseOwnDisputes, type DisputeReviewRow } from '@/data/payrollDisputes';
import { liveConfigured, supabase } from '@/data/supabase';
import { useTheme } from '@/design/theme';
import { useI18n } from '@/i18n';
import { activeWorkspace, backendStore, useBackend } from '@/state/backend';
import { preferencesStore,usePreference } from '@/state/preferences';

const copy={
 en:{title:'Payroll disputes',period:'Payroll period start (YYYY-MM-DD)',load:'Load cases',empty:'No cases for this period.',error:'Unable to load or submit. Check access and refresh.',demo:'Fictional review preview · no live actions',note:'Independent approval records a resolution only. Corrections must use the canonical payroll process.',reason:'Employee concern',proposal:'Proposed resolution',explanation:'Explanation',correction:'Refer for correction',approve:'Approve proposal',decline:'Decline proposal',review:'Review case',noteLabel:'Review explanation (10–1000 characters). Do not include bank or government IDs.',cancel:'Cancel',mine:'My dispute status',statuses:{submitted:'Submitted',pending_approval:'Pending independent approval',explanation:'Explanation approved',correction_required:'Correction required',declined:'Proposal declined'}},
 fil:{title:'Mga payroll dispute',period:'Simula ng payroll (YYYY-MM-DD)',load:'Tingnan ang mga kaso',empty:'Walang kaso sa period na ito.',error:'Hindi ma-load o maisumite. Suriin ang access.',demo:'Halimbawa lamang · walang live na aksyon',note:'Hiwalay na pag-apruba lamang. Sa canonical payroll process ginagawa ang correction.',reason:'Alalahanin ng empleyado',proposal:'Iminungkahing resolusyon',explanation:'Paliwanag',correction:'I-refer para sa correction',approve:'Aprubahan',decline:'Tanggihan',review:'Suriin ang kaso',noteLabel:'Paliwanag (10–1000 karakter). Huwag isama ang bank o government IDs.',cancel:'Kanselahin',mine:'Status ng aking dispute',statuses:{submitted:'Naipasa',pending_approval:'Naghihintay ng hiwalay na pag-apruba',explanation:'Aprubadong paliwanag',correction_required:'Kailangan ng correction',declined:'Tinanggihan ang mungkahi'}},
 es:{title:'Reclamaciones de nómina',period:'Inicio del período (YYYY-MM-DD)',load:'Cargar casos',empty:'No hay casos en este período.',error:'No se pudo cargar o enviar. Revise el acceso.',demo:'Ejemplo ficticio · sin acciones reales',note:'La aprobación independiente registra una resolución. Las correcciones siguen el proceso de nómina canónico.',reason:'Consulta del empleado',proposal:'Resolución propuesta',explanation:'Explicación',correction:'Derivar para corrección',approve:'Aprobar propuesta',decline:'Rechazar propuesta',review:'Revisar caso',noteLabel:'Explicación (10–1000 caracteres). No incluya datos bancarios ni identificadores oficiales.',cancel:'Cancelar',mine:'Estado de mis reclamaciones',statuses:{submitted:'Enviada',pending_approval:'Pendiente de aprobación independiente',explanation:'Explicación aprobada',correction_required:'Corrección requerida',declined:'Propuesta rechazada'}},
} as const;
const demoRows:DisputeReviewRow[]=[{userId:'00000000-0000-4000-8000-000000000002',revision:1,itemIndex:1,status:'submitted',reason:'Fictional overtime duration needs review.',submittedAt:'2026-02-28T00:00:00Z',proposal:null,explanation:null,decisionReason:null,canPropose:true,canDecide:false},{userId:'00000000-0000-4000-8000-000000000003',revision:1,itemIndex:0,status:'pending_approval',reason:'Fictional salary evidence clarification.',submittedAt:'2026-02-28T00:00:00Z',proposal:'explanation',explanation:'Fictional reviewed work evidence.',decisionReason:null,canPropose:false,canDecide:true}];
export function PayrollDisputeDashboard({demo=false}:{demo?:boolean}){
 const t=useTheme(),c=copy[useI18n().locale];
 const state=useBackend(s=>s),selected=usePreference('workspaceId');
 const org=(state.workspaces?.find(w=>w.organizationId===selected)??state.workspaces?.[0])?.organizationId,user=state.userId;
 const [date,setDate]=useState(''),[period,setPeriod]=useState(''),[target,setTarget]=useState(''),[note,setNote]=useState(''),[busy,setBusy]=useState(false),[error,setError]=useState(false);
 const check=()=>{const current=backendStore.get();return preferencesStore.get().backend==='live'&&current.auth==='signed_in'&&current.userId===user&&activeWorkspace(current)?.organizationId===org;};
 const enabled=!demo&&liveConfigured&&state.auth==='signed_in'&&org!==undefined&&user!==undefined&&period!=='';
 const q=useQuery({queryKey:['nforce','dispute-review',user,org,period],enabled,retry:false,gcTime:0,staleTime:0,refetchInterval:15000,queryFn:async()=>{
  if(org===undefined||user===undefined)throw new Error('Unavailable');
  const {data,error}=await supabase().rpc('payroll_dispute_review',{p_organization_id:org,p_period_start:period});
  if(error!==null||!check())throw new Error('Unavailable');
  return parseDisputeReview(data,org,period,user);
 }});
 const rows=demo?demoRows:enabled&&period===date&&!q.isFetching&&!q.isError?q.data?.rows:undefined;
 const key=(r:DisputeReviewRow)=>[r.userId,r.revision,r.itemIndex].join(':');
 const act=async(r:DisputeReviewRow,action:'explanation'|'correction_required'|'approved'|'declined')=>{
  if(demo||busy||!check()||org===undefined||note.trim().length<10||period!==date)return;
  setBusy(true);setError(false);
  try{
   const args={p_organization_id:org,p_period_start:period,p_user_id:r.userId,p_revision:r.revision,p_item_index:r.itemIndex};
   const propose=action==='explanation'||action==='correction_required';
   const {data,error}=propose?await supabase().rpc('payroll_dispute_propose',{...args,p_outcome:action,p_explanation:note.trim()}):await supabase().rpc('payroll_dispute_decide',{...args,p_decision:action,p_reason:note.trim()});
   if(error!==null||!check())throw new Error('Unavailable');decisionResponse.parse(data);setTarget('');setNote('');await q.refetch();
  }catch{setError(true);}finally{setBusy(false);}
 };
 const inputStyle={color:t.colors.text,backgroundColor:t.colors.fill,borderRadius:t.shape.control,padding:t.space.md,minHeight:44};
 return <Card style={{gap:t.space.md}}>
  <Text variant="headline" accessibilityRole="header">{c.title}</Text><Text color="textSecondary" variant="footnote">{c.note}</Text>
  {demo?<Text color="textSecondary" variant="footnote">{c.demo}</Text>:<>
   <TextInput accessibilityLabel={c.period} placeholder="2026-02-01" value={date} maxLength={10} onChangeText={x=>{setDate(x);setTarget('');setNote('');}} style={inputStyle}/>
   <Button title={c.load} disabled={!/^\d{4}-\d{2}-\d{2}$/.test(date)||busy} loading={q.isFetching} onPress={()=>{if(period===date)void q.refetch();else setPeriod(date);}}/>
  </>}
  {q.isError&&<Text color="danger" variant="footnote">{c.error}</Text>}
  {rows?.length===0&&<Text color="textSecondary" variant="footnote">{c.empty}</Text>}
  {rows?.map(r=><View key={key(r)} style={{gap:t.space.sm,padding:t.space.md,backgroundColor:t.colors.fill,borderRadius:t.shape.control}}>
   <Text variant="label" color={r.status==='correction_required'?'warning':r.status==='declined'?'danger':'primary'}>{c.statuses[r.status]}</Text>
   <Text variant="footnote" selectable>{r.userId} · R{r.revision} · #{r.itemIndex+1}</Text>
   <Text variant="footnote" color="textSecondary">{r.submittedAt}</Text>
   <Text variant="subhead" weight="600">{c.reason}</Text><Text variant="body">{r.reason}</Text>
   {r.explanation!==null&&<><Text variant="subhead" weight="600">{c.proposal}: {r.proposal==='explanation'?c.explanation:c.correction}</Text><Text variant="body">{r.explanation}</Text></>}
   {r.decisionReason!==null&&<Text variant="footnote">{r.decisionReason}</Text>}
   {(r.canPropose||r.canDecide)&&<Button title={c.review} variant="tonal" disabled={demo||busy} onPress={()=>{setTarget(key(r));setNote('');setError(false);}}/>}
   {target===key(r)&&<View style={{gap:t.space.sm}}>
    <TextInput accessibilityLabel={c.noteLabel} placeholder={c.noteLabel} multiline maxLength={1000} value={note} onChangeText={setNote} style={inputStyle}/>
    {r.canPropose&&<><Button title={c.explanation} disabled={busy||note.trim().length<10} onPress={()=>void act(r,'explanation')}/><Button title={c.correction} variant="tonal" disabled={busy||note.trim().length<10} onPress={()=>void act(r,'correction_required')}/></>}
    {r.canDecide&&<><Button title={c.approve} disabled={busy||note.trim().length<10} onPress={()=>void act(r,'approved')}/><Button title={c.decline} variant="outlined" disabled={busy||note.trim().length<10} onPress={()=>void act(r,'declined')}/></>}
    <Button title={c.cancel} variant="plain" disabled={busy} onPress={()=>{setTarget('');setNote('');}}/>
    {error&&<Text variant="footnote" color="danger">{c.error}</Text>}
   </View>}
  </View>)}
 </Card>;
}
export function OwnDisputeStatus({org,user,period}:{org:string|undefined;user:string|undefined;period:string|undefined}){
 const t=useTheme(),c=copy[useI18n().locale];
 const auth=useBackend(s=>s.auth),backend=usePreference('backend');
 const enabled=backend==='live'&&auth==='signed_in'&&liveConfigured&&org!==undefined&&user!==undefined&&period!==undefined;
 const q=useQuery({queryKey:['nforce','own-dispute-status',org,user,period],enabled,gcTime:0,staleTime:0,retry:false,refetchInterval:15000,queryFn:async()=>{
  if(org===undefined||period===undefined)throw new Error('Unavailable');
  const {data,error}=await supabase().rpc('payroll_self_dispute_status',{p_organization_id:org,p_period_start:period});
  const current=backendStore.get();if(error!==null||current.auth!=='signed_in'||current.userId!==user||activeWorkspace(current)?.organizationId!==org||preferencesStore.get().backend!=='live')throw new Error('Unavailable');
  return parseOwnDisputes(data,period);
 }});
 const rows=enabled&&!q.isFetching&&!q.isError?q.data:undefined;
 if(rows===undefined||rows.length===0)return null;
 return <Card style={{gap:t.space.sm}}><Text variant="headline">{c.mine}</Text>{rows.map(r=><View key={r.revision+':'+r.itemIndex} style={{gap:t.space.xs}}><Text variant="subhead">R{r.revision} · #{r.itemIndex+1} · {c.statuses[r.status]}</Text>{r.explanation!==null&&<Text variant="footnote">{r.explanation}</Text>}</View>)}</Card>;
}
