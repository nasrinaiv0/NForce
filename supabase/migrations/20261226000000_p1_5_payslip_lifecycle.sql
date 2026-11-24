-- Employee lifecycle projection. No changes to monetary posting or publication.
create function public.payroll_self_history(p_organization_id uuid,p_year int)
returns jsonb language plpgsql security definer set search_path='' as $$
declare u uuid:=auth.uid();r record;v jsonb;items jsonb:='[]';g numeric:=0;ee numeric:=0;t numeric:=0;n numeric:=0;ex numeric:=0;tx numeric:=0;c int:=0;
begin
 if u is null or p_organization_id is null then raise exception 'review unavailable' using errcode='42501';end if;
 perform app.accounting_tenant_lock(p_organization_id);
 if not app.is_member(p_organization_id) or not exists(select 1 from app.accounting_review_access a where a.organization_id=p_organization_id and a.expires_at>clock_timestamp()) then raise exception 'review unavailable' using errcode='42501';end if;
 if p_year is distinct from 2026 then raise exception 'unsupported year' using errcode='22023';end if;
 for r in select m.period_start,m.exempt,m.taxable,m.pay_date from app.ph_effective_monetary m join app.ph_employee_payroll_release rel using(organization_id,period_start,user_id,revision)
 where m.organization_id=p_organization_id and m.user_id=u and extract(year from m.pay_date)=p_year and m.pay_date<=(clock_timestamp() at time zone 'Asia/Manila')::date order by m.period_start desc loop
  v:=public.payroll_self_snapshot(p_organization_id,r.period_start);
  items:=items||jsonb_build_array(v);c:=c+1;
  g:=g+(v->>'grossCents')::numeric;ee:=ee+(v->>'employeeContributionCents')::numeric;t:=t+(v->>'withholdingCents')::numeric;n:=n+(v->>'netCents')::numeric;
  ex:=ex+r.exempt*100;tx:=tx+r.taxable*100;
 end loop;
 return jsonb_build_object('organizationId',p_organization_id,'userId',u,'year',p_year,'coverageComplete',false,'periods',items,'periodCount',c,'grossCents',g::numeric(30,0)::text,'employeeContributionCents',ee::numeric(30,0)::text,'withholdingCents',t::numeric(30,0)::text,'netCents',n::numeric(30,0)::text,'exemptCents',ex::numeric(30,0)::text,'taxableCents',tx::numeric(30,0)::text);
end $$;
create table app.ph_employee_payroll_dispute (
 organization_id uuid not null,period_start date not null,user_id uuid not null,revision int not null,item_index int not null check(item_index between 0 and 9999),
 reason text not null check(char_length(btrim(reason)) between 10 and 500),
 created_at timestamptz not null default clock_timestamp(),
 primary key(organization_id,period_start,user_id,revision,item_index),
 foreign key(organization_id,period_start,user_id,revision) references app.ph_employee_payroll_release
);
alter table app.ph_employee_payroll_dispute enable row level security;
revoke all on app.ph_employee_payroll_dispute from public,anon,authenticated,service_role;
create trigger p15_dispute_immutable before update or delete on app.ph_employee_payroll_dispute for each row execute function app.forbid_mutation();
create function public.payroll_self_dispute(p_organization_id uuid,p_period_start date,p_revision int,p_item_index int,p_reason text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare u uuid:=auth.uid();d jsonb;r app.ph_employee_payroll_dispute;
begin
 d:=public.payroll_self_detail(p_organization_id,p_period_start);
 if p_revision is distinct from (d->'summary'->>'revision')::int or p_item_index is null or p_item_index<0 or p_item_index>=jsonb_array_length(d->'items') or p_reason is null or char_length(btrim(p_reason)) not between 10 and 500 then raise exception 'invalid dispute' using errcode='22023';end if;
 insert into app.ph_employee_payroll_dispute(organization_id,period_start,user_id,revision,item_index,reason) values(p_organization_id,p_period_start,u,p_revision,p_item_index,btrim(p_reason)) on conflict do nothing;
 select * into strict r from app.ph_employee_payroll_dispute where (organization_id,period_start,user_id,revision,item_index)=(p_organization_id,p_period_start,u,p_revision,p_item_index);
 if r.reason<>btrim(p_reason) then raise exception 'item already disputed' using errcode='23505';end if;
 return jsonb_build_object('status','submitted','periodStart',r.period_start,'revision',r.revision,'itemIndex',r.item_index,'submittedAt',r.created_at);
end $$;
create function public.payroll_self_disputes(p_organization_id uuid,p_period_start date)
returns jsonb language plpgsql security definer set search_path='' as $$
declare d jsonb;
begin
 d:=public.payroll_self_snapshot(p_organization_id,p_period_start);
 return coalesce((select jsonb_agg(jsonb_build_object('status','submitted','periodStart',r.period_start,'revision',r.revision,'itemIndex',r.item_index,'submittedAt',r.created_at) order by r.item_index) from app.ph_employee_payroll_dispute r where r.organization_id=p_organization_id and r.user_id=auth.uid() and r.period_start=p_period_start and r.revision=(d->>'revision')::int),'[]'::jsonb);
end $$;
-- Authorized payroll review intake; no ability to alter salary or resolve a case.
create function public.payroll_dispute_inbox(p_organization_id uuid,p_period_start date)
returns jsonb language plpgsql security definer set search_path='' as $$
begin
 if auth.uid() is null or p_organization_id is null then raise exception 'review unavailable' using errcode='42501';end if;
 perform app.accounting_tenant_lock(p_organization_id);
 if not app.has_permission(p_organization_id,'payroll.prepare') or not app.has_permission(p_organization_id,'timesheet.lock') or not exists(select 1 from app.accounting_review_access a where a.organization_id=p_organization_id and a.expires_at>clock_timestamp()) then raise exception 'review unavailable' using errcode='42501';end if;
 return coalesce((select jsonb_agg(jsonb_build_object('userId',r.user_id,'periodStart',r.period_start,'revision',r.revision,'itemIndex',r.item_index,'reason',r.reason,'submittedAt',r.created_at,'status','submitted') order by r.created_at,r.user_id,r.item_index) from app.ph_employee_payroll_dispute r where r.organization_id=p_organization_id and r.period_start=p_period_start),'[]'::jsonb);
end $$;
revoke all on function public.payroll_self_history(uuid,int),public.payroll_self_dispute(uuid,date,int,int,text),public.payroll_self_disputes(uuid,date),public.payroll_dispute_inbox(uuid,date) from public,anon,authenticated,service_role;
grant execute on function public.payroll_self_history(uuid,int),public.payroll_self_dispute(uuid,date,int,int,text),public.payroll_self_disputes(uuid,date),public.payroll_dispute_inbox(uuid,date) to authenticated;
