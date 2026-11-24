-- Full reversal of a private, undispatched accrual only. No automatic payment,
-- tax adjustment, remittance, refund, or replacement posting.
create table app.ph_money_reversal_proposal (
 organization_id uuid not null,user_id uuid not null,pay_month date not null,
 reason text not null check(length(btrim(reason)) between 8 and 300),
 unsettled_reference text not null check(length(btrim(unsettled_reference)) between 8 and 300),
 proposed_by uuid not null references auth.users(id),proposed_at timestamptz not null default clock_timestamp(),
 primary key(organization_id,user_id,pay_month),
 foreign key(organization_id,user_id,pay_month) references app.ph_money_snapshot
);
create table app.ph_money_reversal (
 organization_id uuid not null,user_id uuid not null,pay_month date not null,
 review_reference text not null check(length(btrim(review_reference)) between 8 and 300),
 reviewed_by uuid not null references auth.users(id),reviewed_at timestamptz not null default clock_timestamp(),
 primary key(organization_id,user_id,pay_month),
 foreign key(organization_id,user_id,pay_month) references app.ph_money_reversal_proposal
);
create table app.ph_money_reversal_journal (
 organization_id uuid not null,user_id uuid not null,pay_month date not null,account_code text not null,
 debit numeric not null,credit numeric not null,
 primary key(organization_id,user_id,pay_month,account_code),
 foreign key(organization_id,user_id,pay_month) references app.ph_money_reversal,
 foreign key(organization_id,user_id,pay_month,account_code) references app.ph_money_journal,
 check(debit>=0 and credit>=0 and debit=round(debit,2) and credit=round(credit,2) and (debit=0 or credit=0))
);
do $$ declare n text; begin
 foreach n in array array['ph_money_reversal_proposal','ph_money_reversal','ph_money_reversal_journal'] loop
 execute format('alter table app.%I enable row level security',n);
 execute format('revoke all on app.%I from public,anon,authenticated,service_role',n);
 execute format('create trigger ph_reversal_immutable before update or delete on app.%I for each row execute function app.forbid_mutation()',n);
 execute format('create trigger a_ph_reversal_tenant before insert or update or delete on app.%I for each row execute function app.accounting_write_barrier()',n);
 end loop;
end $$;
create function app.ph_propose_reversal(p_org uuid,p_user uuid,p_month date,p_reason text,p_unsettled text)
returns void language plpgsql set search_path='' as $$
declare old app.ph_money_reversal_proposal;
begin
 perform app.accounting_tenant_lock(p_org);
 if auth.uid() is null or auth.uid()=p_user or not app.has_permission(p_org,'payroll.prepare') or not app.has_permission(p_org,'timesheet.lock') then raise exception 'forbidden' using errcode='42501'; end if;
 if not exists(select 1 from app.ph_money_snapshot where organization_id=p_org and user_id=p_user and pay_month=p_month)
 then raise exception 'original accrual missing' using errcode='P0001'; end if;
 select * into old from app.ph_money_reversal_proposal where organization_id=p_org and user_id=p_user and pay_month=p_month;
 if found then
 if (old.reason,old.unsettled_reference,old.proposed_by) is distinct from (p_reason,p_unsettled,auth.uid()) then raise exception 'reversal proposal conflict' using errcode='22023'; end if;
 return; end if;
 if exists(select 1 from app.ph_money_snapshot where organization_id=p_org and user_id=p_user and pay_month>p_month) then raise exception 'later accruals require reviewed replay' using errcode='P0001'; end if;
 insert into app.ph_money_reversal_proposal(organization_id,user_id,pay_month,reason,unsettled_reference,proposed_by) values(p_org,p_user,p_month,p_reason,p_unsettled,auth.uid());
 insert into public.audit_events(organization_id,actor_id,action,entity,entity_id,data) values(p_org,auth.uid(),'accounting.ph_reversal_proposed','membership',p_user::text,jsonb_build_object('month',p_month));
end $$;
create function app.ph_approve_reversal(p_org uuid,p_user uuid,p_month date,p_review text)
returns void language plpgsql set search_path='' as $$
declare p app.ph_money_reversal_proposal; r app.ph_money_reversal; v numeric;
begin
 perform app.accounting_tenant_lock(p_org);
 if auth.uid() is null or auth.uid()=p_user or not app.has_permission(p_org,'payroll.prepare') or not app.has_permission(p_org,'timesheet.lock') then raise exception 'forbidden' using errcode='42501'; end if;
 select * into p from app.ph_money_reversal_proposal where organization_id=p_org and user_id=p_user and pay_month=p_month;
 if not found or p.proposed_by=auth.uid() then raise exception 'independent reversal review required' using errcode='42501'; end if;
 select * into r from app.ph_money_reversal where organization_id=p_org and user_id=p_user and pay_month=p_month;
 if found then
 if (r.review_reference,r.reviewed_by) is distinct from (p_review,auth.uid()) then raise exception 'reversal review conflict' using errcode='22023'; end if;
 return; end if;
 if exists(select 1 from app.ph_money_snapshot where organization_id=p_org and user_id=p_user and pay_month>p_month) then raise exception 'later accruals require reviewed replay' using errcode='P0001'; end if;
 select sum(debit-credit) into v from app.ph_money_journal where organization_id=p_org and user_id=p_user and pay_month=p_month;
 if v is distinct from 0 then raise exception 'original journal missing or unbalanced' using errcode='P0001'; end if;
 insert into app.ph_money_reversal(organization_id,user_id,pay_month,review_reference,reviewed_by) values(p_org,p_user,p_month,p_review,auth.uid());
 insert into app.ph_money_reversal_journal
 select organization_id,user_id,pay_month,account_code,credit,debit from app.ph_money_journal
 where organization_id=p_org and user_id=p_user and pay_month=p_month;
 select sum(debit-credit) into v from app.ph_money_reversal_journal where organization_id=p_org and user_id=p_user and pay_month=p_month;
 if v is distinct from 0 then raise exception 'unbalanced reversal journal' using errcode='P0001'; end if;
 insert into public.audit_events(organization_id,actor_id,action,entity,entity_id,data) values(p_org,auth.uid(),'accounting.ph_money_reversed','membership',p_user::text,jsonb_build_object('month',p_month));
end $$;
create or replace function app.ph_post_month(p_org uuid,p_user uuid,p_month date)
returns jsonb language plpgsql set search_path='' as $$
declare c app.ph_month_context; h app.ph_employment_history; actual_h app.ph_employment_history; old app.ph_money_snapshot;
 d date; last_day date; ev app.ph_workday_evidence; snap app.accounting_locked_snapshot;
 rate numeric; premium numeric:=0; line jsonb; exact_lines jsonb:='[]'; factor numeric; secs numeric; code text;
 prior_tax numeric:=0; prior_wt numeric:=0; prior_count int:=0; prev_count int:=0; prev_tax numeric:=0; prev_wt numeric:=0;
 sticky boolean:=false; j jsonb; s jsonb; ph jsonb; f jsonb; n int; journal_bal numeric;
begin
 perform app.accounting_tenant_lock(p_org);
 if auth.uid() is null or auth.uid()=p_user or not app.has_permission(p_org,'payroll.prepare') or not app.has_permission(p_org,'timesheet.lock') then raise exception 'forbidden' using errcode='42501'; end if;
 if exists(select 1 from app.ph_money_reversal r where r.organization_id=p_org and r.user_id=p_user and extract(year from r.pay_month)=extract(year from p_month) and r.pay_month<=p_month) then
 raise exception 'reversed accrual requires reviewed monetary replay' using errcode='P0001'; end if;
 select * into old from app.ph_money_snapshot where organization_id=p_org and user_id=p_user and pay_month=p_month;
 if found then return old.calculation; end if;
 select * into c from app.ph_month_context where organization_id=p_org and user_id=p_user and pay_month=p_month;
 if not found or not exists(select 1 from app.ph_month_context_review r where r.organization_id=p_org and r.user_id=p_user and r.pay_month=p_month and r.reviewed_by<>c.prepared_by)
 then raise exception 'independently reviewed monthly context required' using errcode='P0001'; end if;
 if auth.uid()=c.prepared_by then raise exception 'preparer cannot post' using errcode='42501'; end if;
 select * into h from app.ph_employment_history where organization_id=p_org and user_id=p_user and effective_on=c.employment_effective_on and recorded_at=c.employment_recorded_at;
 rate:=app.ph_monthly_hourly(h.rate_php,c.annual_divisor,extract(year from p_month)::int);
 if rate*8<=c.minimum_daily_wage then raise exception 'MWE/underpayment review required' using errcode='P0001'; end if;
 last_day:=(p_month+interval '1 month - 1 day')::date;
 if exists(select 1 from app.ph_money_snapshot z join app.ph_month_context x using(organization_id,user_id,pay_month)
 where z.organization_id=p_org and z.user_id=p_user and (z.pay_month>p_month or x.current_start<>c.current_start))
 then raise exception 'out of order month or changed employment start' using errcode='P0001'; end if;
 if exists(select 1 from app.accounting_adjustment_proposal a where a.organization_id=p_org and a.user_id=p_user and a.period_start<=last_day and a.period_start+7>=p_month)
 then raise exception 'adjustment requires monetary reconciliation' using errcode='P0001'; end if;
 -- No cross-month workday spill in this limited candidate; reject both directions.
 if exists(select 1 from app.accounting_locked_snapshot z cross join lateral jsonb_array_elements(z.reconciliation->'payLines') l
 where z.organization_id=p_org and z.user_id=p_user and
 (((l->>'workday')::date between p_month and last_day) is distinct from ((l->>'date')::date between p_month and last_day)))
 then raise exception 'cross-month workday requires allocation review' using errcode='P0001'; end if;
 for d in select p_month+i from generate_series(0,last_day-p_month)i loop
  actual_h:=app.ph_employment_as_of(p_org,p_user,d,clock_timestamp());
  if actual_h.status<>'employed' or actual_h.pay_basis<>'monthly' or (actual_h.effective_on,actual_h.recorded_at) is distinct from (h.effective_on,h.recorded_at)
  then raise exception 'employment revision changed or partial month' using errcode='P0001'; end if;
  select * into ev from app.ph_workday_evidence where organization_id=p_org and user_id=p_user and work_date=d
    and period_start=d-(extract(isodow from d)::int-1);
  if not found or (ev.employment_effective_on,ev.employment_recorded_at) is distinct from (h.effective_on,h.recorded_at)
  then raise exception 'complete monthly workday evidence required' using errcode='P0001'; end if;
  select * into snap from app.accounting_locked_snapshot where organization_id=p_org and user_id=p_user and period_start=ev.period_start;
  if not found or snap.reconciliation->>'classificationVersion' is distinct from '4'
  or coalesce((snap.reconciliation->>'exactOvertimeReviewSeconds')::numeric,1)>0
  or not exists(select 1 from public.payroll_periods where organization_id=p_org and period_start=ev.period_start)
  then raise exception 'locked exact weekly evidence required' using errcode='P0001'; end if;
  for line in select l from jsonb_array_elements(snap.reconciliation->'payLines') l where (l->>'workday')::date=d loop
   factor:=(line->>'multiplier')::numeric; secs:=(line->>'seconds')::numeric; code:=line->>'code';
   if factor is null or factor<1 or factor>10 or secs is null or secs<=0 or secs>86400 or code is null then raise exception 'invalid locked premium evidence' using errcode='P0001'; end if;
   -- Monthly base already covers non-OT hours. For OT, full multiplier applies.
   premium:=premium+rate*secs/3600*(factor-case when code~'(^|_)OT(_|$)' then 0 else 1 end);
   exact_lines:=exact_lines||jsonb_build_array(line);
  end loop;
 end loop;
 premium:=round(premium,2);
 -- Prior present-employer months must be contiguous from the attested start.
 select count(*),coalesce(sum(taxable),0),coalesce(sum(withholding),0),coalesce(bool_or((calculation->>'cumulative')::boolean),false)
 into prior_count,prior_tax,prior_wt,sticky from app.ph_money_snapshot
 where organization_id=p_org and user_id=p_user and pay_month>=c.current_start and pay_month<p_month;
 n:=(extract(month from p_month)-extract(month from c.current_start))::int;
 if prior_count<>n or exists(select 1 from app.ph_money_snapshot where organization_id=p_org and user_id=p_user and pay_month>=date '2025-01-01' and pay_month<c.current_start)
 then raise exception 'incomplete or inconsistent present-employer monthly history' using errcode='P0001'; end if;
 if exists(select 1 from app.ph_2316_import i left join app.ph_2316_review r on r.import_id=i.id
 left join app.ph_2316_custody_review v on v.import_id=i.id and v.organization_id=i.organization_id
 where i.organization_id=p_org and i.user_id=p_user and i.tax_year=2025 and
 (r.import_id is null or (r.approved and (v.import_id is null or i.period_to>=c.current_start
 or extract(day from i.period_from)<>1 or i.period_to<>(date_trunc('month',i.period_to)+interval '1 month - 1 day')::date))))
 then raise exception 'incomplete custody or unsupported prior employer period' using errcode='P0001'; end if;
 select coalesce(sum((i.fields->>'21')::numeric),0),coalesce(sum((i.fields->>'25A')::numeric),0),
 coalesce(sum(extract(month from i.period_to)-extract(month from i.period_from)+1),0)::int
 into prev_tax,prev_wt,prev_count from app.ph_2316_import i join app.ph_2316_review r on r.import_id=i.id and r.approved
 join app.ph_2316_custody_review v on v.import_id=i.id and v.organization_id=i.organization_id
 where i.organization_id=p_org and i.user_id=p_user and i.tax_year=2025;
 j:=app.ph_month_amounts(h.rate_php,premium,p_month,c.sss_basis,c.philhealth_basis,c.pagibig_basis,
 prior_tax+prev_tax,prior_wt+prev_wt,prior_count+prev_count+1,sticky or prev_count>0)
 ||jsonb_build_object('sourceVersion',1,'monthlyDivisor',c.annual_divisor,'hourlyRate',rate,'employmentEffectiveOn',h.effective_on,
 'employmentRecordedAt',h.recorded_at,'exactPayLines',exact_lines,'priorTaxable',prior_tax+prev_tax,'priorWithheld',prior_wt+prev_wt,'priorPeriods',prior_count+prev_count);
 s:=j->'sss';ph:=j->'philhealth';f:=j->'pagibig';
 insert into app.ph_money_snapshot(organization_id,user_id,pay_month,gross,employee_contrib,employer_contrib,taxable,withholding,net,employer_cost,calculation,created_by)
 values(p_org,p_user,p_month,(j->>'gross')::numeric,(j->>'employeeContrib')::numeric,(j->>'employerContrib')::numeric,(j->>'taxable')::numeric,(j->>'withholding')::numeric,(j->>'net')::numeric,(j->>'employerCost')::numeric,j,auth.uid());
 insert into app.ph_money_journal
 select p_org,p_user,p_month,v.code,v.debit,v.credit from (values
 ('salary_expense',(j->>'gross')::numeric,0::numeric),
 ('employer_contribution_expense',(j->>'employerContrib')::numeric,0),
 ('salary_payable',0,(j->>'net')::numeric),
 ('bir_withholding_payable',0,(j->>'withholding')::numeric),
 ('sss_regular_payable',0,(s->>'employeeRegular')::numeric+(s->>'employerRegular')::numeric),
 ('sss_mpf_payable',0,(s->>'employeeMpf')::numeric+(s->>'employerMpf')::numeric),
 ('sss_ec_payable',0,(s->>'employerEc')::numeric),
 ('philhealth_payable',0,(ph->>'total')::numeric),
 ('pagibig_payable',0,(f->>'total')::numeric)
 ) v(code,debit,credit) where v.debit<>0 or v.credit<>0;
 select sum(debit-credit) into journal_bal from app.ph_money_journal where organization_id=p_org and user_id=p_user and pay_month=p_month;
 if journal_bal is distinct from 0 then raise exception 'unbalanced monetary journal' using errcode='P0001'; end if;
 insert into public.audit_events(organization_id,actor_id,action,entity,entity_id,data)
 values(p_org,auth.uid(),'accounting.ph_money_posted','membership',p_user::text,jsonb_build_object('month',p_month));
 return j;
end $$;

revoke all on function app.ph_propose_reversal(uuid,uuid,date,text,text),app.ph_approve_reversal(uuid,uuid,date,text),app.ph_post_month(uuid,uuid,date)
from public,anon,authenticated,service_role;
