-- Resolution only: no writes to canonical compensation, release or journal tables.
create table app.ph_dispute_proposal (
 organization_id uuid not null,period_start date not null,user_id uuid not null,revision int not null,item_index int not null,
 outcome text not null check(outcome in ('explanation','correction_required')),
 explanation text not null check(char_length(btrim(explanation)) between 10 and 1000),
 proposed_by uuid not null references auth.users(id),proposed_at timestamptz not null default clock_timestamp(),
 primary key(organization_id,period_start,user_id,revision,item_index),
 foreign key(organization_id,period_start,user_id,revision,item_index) references app.ph_employee_payroll_dispute,
 check(proposed_by<>user_id)
);
create table app.ph_dispute_decision (
 organization_id uuid not null,period_start date not null,user_id uuid not null,revision int not null,item_index int not null,
 decision text not null check(decision in ('approved','declined')),
 reason text not null check(char_length(btrim(reason)) between 10 and 1000),
 decided_by uuid not null references auth.users(id),decided_at timestamptz not null default clock_timestamp(),
 primary key(organization_id,period_start,user_id,revision,item_index),
 foreign key(organization_id,period_start,user_id,revision,item_index) references app.ph_dispute_proposal,
 check(decided_by<>user_id)
);
alter table app.ph_dispute_proposal enable row level security;
alter table app.ph_dispute_decision enable row level security;
revoke all on app.ph_dispute_proposal,app.ph_dispute_decision from public,anon,authenticated,service_role;
create trigger p15_dispute_proposal_immutable before update or delete on app.ph_dispute_proposal for each row execute function app.forbid_mutation();
create trigger p15_dispute_decision_immutable before update or delete on app.ph_dispute_decision for each row execute function app.forbid_mutation();
create function app.ph_dispute_review_gate(p_org uuid) returns void language plpgsql set search_path='' as $$
begin
 if auth.uid() is null or p_org is null then raise exception 'review unavailable' using errcode='42501';end if;
 perform app.accounting_tenant_lock(p_org);
 if not app.is_member(p_org) or not app.has_permission(p_org,'payroll.prepare') or not app.has_permission(p_org,'timesheet.lock') or not exists(select 1 from app.accounting_review_access a where a.organization_id=p_org and a.expires_at>clock_timestamp()) then raise exception 'review unavailable' using errcode='42501';end if;
end $$;
revoke all on function app.ph_dispute_review_gate(uuid) from public,anon,authenticated,service_role;
create function public.payroll_dispute_review(p_organization_id uuid,p_period_start date)
returns jsonb language plpgsql security definer set search_path='' as $$
begin
 perform app.ph_dispute_review_gate(p_organization_id);
 if p_period_start is null then raise exception 'invalid period' using errcode='22023';end if;
 return jsonb_build_object('organizationId',p_organization_id,'periodStart',p_period_start,'rows',coalesce((select jsonb_agg(jsonb_build_object(
 'userId',r.user_id,'revision',r.revision,'itemIndex',r.item_index,'reason',r.reason,'submittedAt',r.created_at,
 'status',case when d.decision='approved' then p.outcome when d.decision='declined' then 'declined' when p.proposed_by is not null then 'pending_approval' else 'submitted' end,
 'proposal',p.outcome,'explanation',p.explanation,'decisionReason',d.reason,
 'canPropose',r.user_id<>auth.uid() and p.proposed_by is null,
 'canDecide',r.user_id<>auth.uid() and p.proposed_by is not null and p.proposed_by<>auth.uid() and d.decided_by is null)
 order by r.created_at,r.user_id,r.revision,r.item_index)
 from app.ph_employee_payroll_dispute r left join app.ph_dispute_proposal p using(organization_id,period_start,user_id,revision,item_index)
 left join app.ph_dispute_decision d using(organization_id,period_start,user_id,revision,item_index)
 where r.organization_id=p_organization_id and r.period_start=p_period_start),'[]'::jsonb));
end $$;
create function public.payroll_dispute_propose(p_organization_id uuid,p_period_start date,p_user_id uuid,p_revision int,p_item_index int,p_outcome text,p_explanation text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare p app.ph_dispute_proposal;
begin
 perform app.ph_dispute_review_gate(p_organization_id);
 if p_user_id is null or p_user_id=auth.uid() then raise exception 'self review forbidden' using errcode='42501';end if;
 if p_outcome is null or p_outcome not in ('explanation','correction_required') or p_explanation is null or char_length(btrim(p_explanation)) not between 10 and 1000 then raise exception 'invalid proposal' using errcode='22023';end if;
 if not exists(select 1 from app.ph_employee_payroll_dispute r where (r.organization_id,r.period_start,r.user_id,r.revision,r.item_index)=(p_organization_id,p_period_start,p_user_id,p_revision,p_item_index)) then raise exception 'dispute unavailable' using errcode='P0001';end if;
 insert into app.ph_dispute_proposal(organization_id,period_start,user_id,revision,item_index,outcome,explanation,proposed_by) values(p_organization_id,p_period_start,p_user_id,p_revision,p_item_index,p_outcome,btrim(p_explanation),auth.uid()) on conflict do nothing;
 select * into strict p from app.ph_dispute_proposal r where (r.organization_id,r.period_start,r.user_id,r.revision,r.item_index)=(p_organization_id,p_period_start,p_user_id,p_revision,p_item_index);
 if p.proposed_by<>auth.uid() or p.outcome<>p_outcome or p.explanation<>btrim(p_explanation) then raise exception 'proposal already exists' using errcode='23505';end if;
 return jsonb_build_object('status','pending_approval');
end $$;
create function public.payroll_dispute_decide(p_organization_id uuid,p_period_start date,p_user_id uuid,p_revision int,p_item_index int,p_decision text,p_reason text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare p app.ph_dispute_proposal;d app.ph_dispute_decision;
begin
 perform app.ph_dispute_review_gate(p_organization_id);
 if p_user_id is null or p_user_id=auth.uid() then raise exception 'self review forbidden' using errcode='42501';end if;
 if p_decision is null or p_decision not in ('approved','declined') or p_reason is null or char_length(btrim(p_reason)) not between 10 and 1000 then raise exception 'invalid decision' using errcode='22023';end if;
 select * into p from app.ph_dispute_proposal r where (r.organization_id,r.period_start,r.user_id,r.revision,r.item_index)=(p_organization_id,p_period_start,p_user_id,p_revision,p_item_index);
 if not found then raise exception 'proposal unavailable' using errcode='P0001';end if;
 if p.proposed_by=auth.uid() then raise exception 'independent approval required' using errcode='42501';end if;
 if not app.has_role(p_organization_id,p.proposed_by,array['payroll','owner']) then raise exception 'maker no longer authorized' using errcode='42501';end if;
 insert into app.ph_dispute_decision(organization_id,period_start,user_id,revision,item_index,decision,reason,decided_by) values(p_organization_id,p_period_start,p_user_id,p_revision,p_item_index,p_decision,btrim(p_reason),auth.uid()) on conflict do nothing;
 select * into strict d from app.ph_dispute_decision r where (r.organization_id,r.period_start,r.user_id,r.revision,r.item_index)=(p_organization_id,p_period_start,p_user_id,p_revision,p_item_index);
 if d.decided_by<>auth.uid() or d.decision<>p_decision or d.reason<>btrim(p_reason) then raise exception 'decision already exists' using errcode='23505';end if;
 return jsonb_build_object('status',case when d.decision='approved' then p.outcome else 'declined' end);
end $$;
-- Historical own disputes remain visible after a correction; no old monetary fields.
create function public.payroll_self_dispute_status(p_organization_id uuid,p_period_start date)
returns jsonb language plpgsql security definer set search_path='' as $$
begin
 if auth.uid() is null or p_organization_id is null then raise exception 'review unavailable' using errcode='42501';end if;
 perform app.accounting_tenant_lock(p_organization_id);
 if not app.is_member(p_organization_id) or not exists(select 1 from app.accounting_review_access a where a.organization_id=p_organization_id and a.expires_at>clock_timestamp()) then raise exception 'review unavailable' using errcode='42501';end if;
 return coalesce((select jsonb_agg(jsonb_build_object('periodStart',r.period_start,'revision',r.revision,'itemIndex',r.item_index,
 'status',case when d.decision='approved' then p.outcome when d.decision='declined' then 'declined' when p.proposed_by is not null then 'pending_approval' else 'submitted' end,
 'explanation',case when d.decision='approved' then p.explanation else null end)
 order by r.revision,r.item_index) from app.ph_employee_payroll_dispute r left join app.ph_dispute_proposal p using(organization_id,period_start,user_id,revision,item_index)
 left join app.ph_dispute_decision d using(organization_id,period_start,user_id,revision,item_index) where r.organization_id=p_organization_id and r.user_id=auth.uid() and r.period_start=p_period_start),'[]'::jsonb);
end $$;
revoke all on function public.payroll_dispute_review(uuid,date),public.payroll_dispute_propose(uuid,date,uuid,int,int,text,text),public.payroll_dispute_decide(uuid,date,uuid,int,int,text,text),public.payroll_self_dispute_status(uuid,date) from public,anon,authenticated,service_role;
grant execute on function public.payroll_dispute_review(uuid,date),public.payroll_dispute_propose(uuid,date,uuid,int,int,text,text),public.payroll_dispute_decide(uuid,date,uuid,int,int,text,text),public.payroll_self_dispute_status(uuid,date) to authenticated;
