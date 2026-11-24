import { router, type Href } from 'expo-router';
import { Avatar, Pill } from '@/components/Display';
import { LoadingBlock, Screen, ErrorState } from '@/components/Screen';
import { Card, ListRow, ListSection } from '@/components/Surface';
import { Text } from '@/components/Text';
import { personalNavigation } from '@/data/personalNavigation';
import { useSession } from '@/data/queries';
import { useTheme } from '@/design/theme';
import { useI18n } from '@/i18n';
import { useBackend } from '@/state/backend';
import { usePreference } from '@/state/preferences';

export default function MyProfileScreen(){
 const i18n=useI18n(),t=useTheme(),c=personalNavigation[i18n.locale];
 const session=useSession(),backend=usePreference('backend'),persona=usePreference('persona');
 const state=useBackend(s=>s);
 const selected=usePreference('workspaceId');
 const workspace=state.workspaces?.find(w=>w.organizationId===selected)??state.workspaces?.[0];
 const current=session.data;
 const valid=current!==undefined&&(backend==='demo'?current.role===persona:state.auth==='signed_in'&&current.user.id===state.userId&&current.organization.id===workspace?.organizationId&&current.role===workspace?.role);
 if(session.isError)return <Screen><ErrorState message={i18n.t('common.errorBody')} onRetry={()=>void session.refetch()}/></Screen>;
 if(!valid||current===undefined)return <Screen><LoadingBlock rows={2} height={88}/></Screen>;
 return <Screen>
  <Card style={{gap:t.space.md,alignItems:'center'}}>
    <Avatar initials={current.user.initials} hue={current.user.hue} size={80}/>
    <Text variant="title2" accessibilityRole="header">{current.user.name}</Text>
    <Text variant="subhead" color="textSecondary">{current.user.title}</Text>
    <Pill label={i18n.t(`role.${current.role}`)} tone="primary" icon="shield"/>
    <Text variant="footnote" color="textSecondary">{current.organization.name}</Text>
    {current.teamName!==undefined&&<Text variant="footnote" color="textSecondary">{current.teamName}</Text>}
  </Card>
  <ListSection title={c.identity}>
    <ListRow title={c.record} icon="person" onPress={()=>router.push({pathname:'/more/person/[id]',params:{id:current.user.id}})}/>
    <ListRow title={c.payslip} icon="payroll" onPress={()=>router.push('/more/my-payslip' as Href)} last/>
  </ListSection>
  {current.manager!==undefined&&<ListSection title={i18n.t('more.reportsTo')}><ListRow title={current.manager.name} subtitle={current.manager.title} leading={<Avatar initials={current.manager.initials} hue={current.manager.hue} size={36}/>} last/></ListSection>}
 </Screen>;
}
