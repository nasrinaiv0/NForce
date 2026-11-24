-- Selective port of PR14 authorization serialization and disabled-by-default exact-second review.
create table app.accounting_review_access (
  organization_id uuid primary key references public.organizations(id),
  evidence_reference text not null check(length(btrim(evidence_reference)) between 8 and 250),
  enabled_by uuid not null references auth.users(id),
  expires_at timestamptz not null,
  enabled_at timestamptz not null default now(),
  check(expires_at>enabled_at and expires_at<=enabled_at+interval '7 days')
);
alter table app.accounting_review_access enable row level security;
revoke all on app.accounting_review_access from public,anon,authenticated,service_role;
create trigger p05_review_access_barrier before insert or update or delete on app.accounting_review_access
for each row execute function app.accounting_write_barrier();

-- Authorization mutation barrier. Tenant role and membership grant mutations
-- share the accounting lock; platform role templates are migration-owned.
create function app.accounting_auth_barrier() returns trigger
language plpgsql security definer set search_path='' as $$
declare old_org uuid; new_org uuid; o uuid;
begin
  if tg_table_name='membership_roles' then
    if tg_op<>'INSERT' then select organization_id into old_org from public.memberships where id=old.membership_id; end if;
    if tg_op<>'DELETE' then select organization_id into new_org from public.memberships where id=new.membership_id; end if;
  elsif tg_table_name='role_grants' then
    if tg_op<>'INSERT' then select organization_id into old_org from public.roles where id=old.role_id; end if;
    if tg_op<>'DELETE' then select organization_id into new_org from public.roles where id=new.role_id; end if;
  else
    if tg_op<>'INSERT' then old_org:=old.organization_id; end if;
    if tg_op<>'DELETE' then new_org:=new.organization_id; end if;
  end if;
  if tg_op='UPDATE' and old_org is distinct from new_org then raise exception 'tenant immutable' using errcode='42501'; end if;
  o:=coalesce(new_org,old_org);
  if o is not null and not pg_try_advisory_xact_lock(hashtextextended('nforce-accounting-v4:'||o::text,0)) then
    raise exception 'authorization tenant busy; retry transaction' using errcode='40001'; end if;
  if tg_op='DELETE' then return old; end if; return new;
end $$;
create trigger a_p05_auth_barrier before insert or update or delete on public.membership_roles for each row execute function app.accounting_auth_barrier();
create trigger a_p05_auth_barrier before insert or update or delete on public.role_grants for each row execute function app.accounting_auth_barrier();
create trigger a_p05_auth_barrier before insert or update or delete on public.roles for each row execute function app.accounting_auth_barrier();
create trigger a_p05_auth_barrier before insert or update or delete on public.delegations for each row execute function app.accounting_auth_barrier();
create trigger a_p05_auth_barrier before insert or update or delete on public.team_members for each row execute function app.accounting_auth_barrier();
create trigger a_p05_auth_barrier before insert or update or delete on public.approval_steps for each row execute function app.accounting_auth_barrier();

create function public.accounting_review_snapshot(p_organization_id uuid,p_period_start date,p_scope text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare r jsonb; u uuid:=auth.uid(); n int;
begin
  if u is null or p_scope is null or p_scope not in ('self','organization') or p_period_start is null or extract(isodow from p_period_start)<>1 then
    raise exception 'accounting review unavailable' using errcode='42501'; end if;
  perform app.accounting_tenant_lock(p_organization_id);
  if not app.is_member(p_organization_id) or (p_scope='organization' and not app.has_permission(p_organization_id,'payroll.prepare'))
    or not exists(select 1 from app.accounting_review_access g where g.organization_id=p_organization_id and g.expires_at>clock_timestamp()) then
    raise exception 'accounting review unavailable' using errcode='42501'; end if;
  if not exists(select 1 from public.payroll_periods where organization_id=p_organization_id and period_start=p_period_start) then
    raise exception 'locked review unavailable' using errcode='P0001'; end if;
  select count(*) into n from app.accounting_locked_snapshot s where s.organization_id=p_organization_id and s.period_start=p_period_start
    and (p_scope='organization' or s.user_id=u);
  if n=0 or exists(select 1 from app.accounting_locked_snapshot s where s.organization_id=p_organization_id and s.period_start=p_period_start
    and (p_scope='organization' or s.user_id=u) and (s.reconciliation->>'classificationVersion' is distinct from '4' or jsonb_typeof(s.reconciliation->'payLines') is distinct from 'array')) then
    raise exception 'classified locked review unavailable' using errcode='P0001'; end if;
  with snapshots as (
    select reconciliation as x from app.accounting_locked_snapshot where organization_id=p_organization_id and period_start=p_period_start and (p_scope='organization' or user_id=u)
  ), totals as (
    select sum((x->>'workedSeconds')::numeric) worked,sum((x->>'overtimeSeconds')::numeric) ot from snapshots
  ), codes as (
    select l->>'code' code,sum((l->>'seconds')::numeric) seconds from snapshots cross join lateral jsonb_array_elements(x->'payLines')l group by 1
  )
  select jsonb_build_object('organizationId',p_organization_id,'periodStart',p_period_start,'scope',p_scope,
    'employeeCount',n,'workedSeconds',totals.worked::text,'overtimeSeconds',totals.ot::text,'source','locked-original-ph-v4',
    'lines',coalesce((select jsonb_agg(jsonb_build_object('code',code,'seconds',seconds::text) order by code) from codes),'[]'::jsonb))
    into r from totals;
  return r;
end $$;
revoke all on function app.accounting_auth_barrier() from public,anon,authenticated,service_role;
revoke all on function public.accounting_review_snapshot(uuid,date,text) from public,anon,authenticated,service_role;
grant execute on function public.accounting_review_snapshot(uuid,date,text) to authenticated;

