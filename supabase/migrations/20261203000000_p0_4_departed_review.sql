
-- Separate preparer and approver for a departed employee; no login restoration.
create table app.accounting_departed_review (
  organization_id uuid not null,period_start date not null,user_id uuid not null,
  reconciliation jsonb not null,evidence_reference text not null check(length(btrim(evidence_reference)) between 1 and 250),
  prepared_by uuid not null references auth.users(id),prepared_at timestamptz not null default now(),
  primary key(organization_id,period_start,user_id),
  foreign key(organization_id,period_start) references app.accounting_period_manifest,
  foreign key(organization_id,user_id) references public.memberships(organization_id,user_id)
);
create table app.accounting_departed_decision (
  organization_id uuid not null,period_start date not null,user_id uuid not null,
  approved_by uuid not null references auth.users(id),approved_at timestamptz not null default now(),
  primary key(organization_id,period_start,user_id),
  foreign key(organization_id,period_start,user_id) references app.accounting_departed_review
);
do $$
declare n text;
begin
  foreach n in array array['accounting_departed_review','accounting_departed_decision'] loop
    execute format('revoke all on app.%I from public,anon,authenticated,service_role',n);
    execute format('alter table app.%I enable row level security',n);
    execute format('create trigger p04_immutable before update or delete on app.%I for each row execute function app.forbid_mutation()',n);
  end loop;
end $$;
create function app.accounting_prepare_departed(p_org uuid,p_period date,p_user uuid,p_evidence text)
returns void language plpgsql set search_path='' as $$
declare r jsonb;
begin
  perform app.accounting_tenant_lock(p_org);
  if auth.uid() is null or auth.uid()=p_user or not app.has_permission(p_org,'payroll.prepare') or not app.has_permission(p_org,'timesheet.adjust') then raise exception 'forbidden' using errcode='42501'; end if;
  if not exists(select 1 from public.memberships where organization_id=p_org and user_id=p_user and status='ended') then raise exception 'departed employee required' using errcode='P0001'; end if;
  if exists(select 1 from public.payroll_periods where organization_id=p_org and period_start=p_period) then raise exception 'period already locked' using errcode='P0001'; end if;
  r:=app.accounting_reconcile(p_org,p_period,p_user);
  if not (r ? 'payLines') or (r->>'unapprovedOvertime')::int<>0 or coalesce((r->>'exactOvertimeReviewSeconds')::numeric,0)>0 then raise exception 'classified reconciled hours required' using errcode='P0001'; end if;
  if exists(select 1 from public.timesheets where organization_id=p_org and period_start=p_period and user_id=p_user and status not in ('draft','returned')) then raise exception 'existing sheet requires review' using errcode='P0001'; end if;
  insert into app.accounting_departed_review(organization_id,period_start,user_id,reconciliation,evidence_reference,prepared_by)
    values(p_org,p_period,p_user,r,p_evidence,auth.uid());
  insert into public.audit_events(organization_id,actor_id,action,entity,entity_id,data)
    values(p_org,auth.uid(),'accounting.departed_prepared','membership',p_user::text,jsonb_build_object('periodStart',p_period));
end $$;
create function app.accounting_approve_departed(p_org uuid,p_period date,p_user uuid)
returns void language plpgsql set search_path='' as $$
declare a app.accounting_departed_review; r jsonb; sheet public.timesheets;
begin
  perform app.accounting_tenant_lock(p_org);
  if auth.uid() is null or auth.uid()=p_user or not app.has_permission(p_org,'payroll.prepare') or not app.has_permission(p_org,'timesheet.adjust') then raise exception 'forbidden' using errcode='42501'; end if;
  select * into a from app.accounting_departed_review where organization_id=p_org and period_start=p_period and user_id=p_user;
  if not found or a.prepared_by=auth.uid() then raise exception 'independent review required' using errcode='42501'; end if;
  if not exists(select 1 from public.memberships where organization_id=p_org and user_id=p_user and status='ended') or exists(select 1 from public.payroll_periods where organization_id=p_org and period_start=p_period) then raise exception 'employee or period changed' using errcode='P0001'; end if;
  r:=app.accounting_reconcile(p_org,p_period,p_user);
  if r is distinct from a.reconciliation then raise exception 'reconciliation changed' using errcode='P0001'; end if;
  insert into public.timesheets(organization_id,user_id,period_start) values(p_org,p_user,p_period) on conflict do nothing;
  select * into sheet from public.timesheets where organization_id=p_org and user_id=p_user and period_start=p_period for update;
  if sheet.status not in ('draft','returned') then raise exception 'existing sheet requires review' using errcode='P0001'; end if;
  update public.timesheets set status='approved',worked_minutes=(r->>'worked')::int,overtime_minutes=(r->>'overtime')::int,submitted_at=now(),decided_at=now() where id=sheet.id;
  insert into app.accounting_submission values(p_org,p_period,p_user,r,sheet.id) on conflict(organization_id,period_start,user_id) do update set reconciliation=excluded.reconciliation,sheet_id=excluded.sheet_id;
  insert into app.accounting_departed_decision(organization_id,period_start,user_id,approved_by) values(p_org,p_period,p_user,auth.uid());
  insert into public.audit_events(organization_id,actor_id,action,entity,entity_id,data) values(p_org,auth.uid(),'accounting.departed_approved','membership',p_user::text,jsonb_build_object('periodStart',p_period));
end $$;
revoke all on function app.accounting_prepare_departed(uuid,date,uuid,text),app.accounting_approve_departed(uuid,date,uuid) from public,anon,authenticated,service_role;
