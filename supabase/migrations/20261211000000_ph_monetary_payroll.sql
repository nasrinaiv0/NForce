-- Restricted monthly payroll candidate: genuinely monthly-paid ordinary non-MWE,
-- full calendar-month basic salary; Jan-Nov 2025 only (PhilHealth schedule verified).
-- No leave/absence deductions, fringe benefits, final pay, benefits or adjustments.
-- A reviewed context attests the scope; unsupported cases must not be paid from this path.
create table app.ph_month_context (
 organization_id uuid not null,user_id uuid not null,pay_month date not null,
 current_start date not null,employment_effective_on date not null,employment_recorded_at timestamptz not null,
 annual_divisor numeric not null,minimum_daily_wage numeric not null check(minimum_daily_wage>0 and minimum_daily_wage<=1000000 and minimum_daily_wage=round(minimum_daily_wage,2)),
 sss_basis numeric not null,philhealth_basis numeric not null,pagibig_basis numeric not null,
 scope_reference text not null check(length(btrim(scope_reference)) between 1 and 300),
 prepared_by uuid not null references auth.users(id),prepared_at timestamptz not null default clock_timestamp(),
 primary key(organization_id,user_id,pay_month),
 foreign key(organization_id,user_id,employment_effective_on,employment_recorded_at) references app.ph_employment_history,
 check(pay_month between date '2025-01-01' and date '2025-11-01' and extract(day from pay_month)=1),
 check(current_start between date '2025-01-01' and pay_month and extract(day from current_start)=1),
 check(annual_divisor=365),
 check(sss_basis>0 and sss_basis<=1000000000 and sss_basis=round(sss_basis,2)),
 check(philhealth_basis>0 and philhealth_basis<=1000000000 and philhealth_basis=round(philhealth_basis,2)),
 check(pagibig_basis>0 and pagibig_basis<=1000000000 and pagibig_basis=round(pagibig_basis,2))
);
create table app.ph_month_context_review (
 organization_id uuid not null,user_id uuid not null,pay_month date not null,
 review_reference text not null check(length(btrim(review_reference)) between 1 and 300),
 reviewed_by uuid not null references auth.users(id),reviewed_at timestamptz not null default clock_timestamp(),
 primary key(organization_id,user_id,pay_month),
 foreign key(organization_id,user_id,pay_month) references app.ph_month_context
);
create table app.ph_money_snapshot (
 organization_id uuid not null,user_id uuid not null,pay_month date not null,
 gross numeric not null,employee_contrib numeric not null,employer_contrib numeric not null,
 taxable numeric not null,withholding numeric not null,net numeric not null,employer_cost numeric not null,
 calculation jsonb not null,created_by uuid not null references auth.users(id),created_at timestamptz not null default clock_timestamp(),
 primary key(organization_id,user_id,pay_month),
 foreign key(organization_id,user_id,pay_month) references app.ph_month_context_review,
 check(gross>=0 and employee_contrib>=0 and employer_contrib>=0 and taxable>=0 and withholding>=0 and net>=0),
 check(net=gross-employee_contrib-withholding and employer_cost=gross+employer_contrib and taxable=gross-employee_contrib)
);
create table app.ph_money_journal (
 organization_id uuid not null,user_id uuid not null,pay_month date not null,account_code text not null,
 debit numeric not null,credit numeric not null,
 primary key(organization_id,user_id,pay_month,account_code),
 foreign key(organization_id,user_id,pay_month) references app.ph_money_snapshot,
 check(debit>=0 and credit>=0 and debit=round(debit,2) and credit=round(credit,2) and (debit=0 or credit=0))
);
do $$ declare n text; begin
 foreach n in array array['ph_month_context','ph_month_context_review','ph_money_snapshot','ph_money_journal'] loop
 execute format('alter table app.%I enable row level security',n);
 execute format('revoke all on app.%I from public,anon,authenticated,service_role',n);
 execute format('create trigger ph_money_immutable before update or delete on app.%I for each row execute function app.forbid_mutation()',n);
 execute format('create trigger a_ph_money_tenant before insert or update or delete on app.%I for each row execute function app.accounting_write_barrier()',n);
 end loop;
end $$;
create function app.ph_prepare_month(p_org uuid,p_user uuid,p_month date,p_start date,p_divisor numeric,p_min_wage numeric,
 p_sss numeric,p_ph numeric,p_hdmf numeric,p_reference text)
returns void language plpgsql set search_path='' as $$
declare h app.ph_employment_history;
begin
 perform app.accounting_tenant_lock(p_org);
 if auth.uid() is null or auth.uid()=p_user or not app.has_permission(p_org,'payroll.prepare') then raise exception 'forbidden' using errcode='42501'; end if;
 h:=app.ph_employment_as_of(p_org,p_user,p_month,clock_timestamp());
 if h.status<>'employed' or h.pay_basis<>'monthly' then raise exception 'supported monthly employment required' using errcode='P0001'; end if;
 if app.ph_monthly_hourly(h.rate_php,p_divisor,extract(year from p_month)::integer)*8<=p_min_wage then raise exception 'MWE or wage underpayment requires separate classification' using errcode='P0001'; end if;
 insert into app.ph_month_context(organization_id,user_id,pay_month,current_start,employment_effective_on,employment_recorded_at,annual_divisor,
 minimum_daily_wage,sss_basis,philhealth_basis,pagibig_basis,scope_reference,prepared_by)
 values(p_org,p_user,p_month,p_start,h.effective_on,h.recorded_at,p_divisor,p_min_wage,p_sss,p_ph,p_hdmf,p_reference,auth.uid());
end $$;
create function app.ph_review_month(p_org uuid,p_user uuid,p_month date,p_reference text)
returns void language plpgsql set search_path='' as $$
declare c app.ph_month_context;
begin
 perform app.accounting_tenant_lock(p_org);
 if auth.uid() is null or auth.uid()=p_user or not app.has_permission(p_org,'payroll.prepare') then raise exception 'forbidden' using errcode='42501'; end if;
 select * into c from app.ph_month_context where organization_id=p_org and user_id=p_user and pay_month=p_month;
 if not found or c.prepared_by=auth.uid() then raise exception 'independent review required' using errcode='42501'; end if;
 insert into app.ph_month_context_review(organization_id,user_id,pay_month,review_reference,reviewed_by) values(p_org,p_user,p_month,p_reference,auth.uid());
end $$;
-- Pure reconciled money arithmetic. Agency bases are separately attested, not silently
-- inferred for every employment class. Here only regular salary and premium pay exist.
create function app.ph_month_amounts(p_basic numeric,p_premium numeric,p_month date,p_sss numeric,p_ph numeric,p_hdmf numeric,
 p_prior_taxable numeric,p_prior_withheld numeric,p_periods int,p_cumulative boolean)
returns jsonb language plpgsql immutable set search_path='' as $$
declare s jsonb; h jsonb; f jsonb; gross numeric; ee numeric; er numeric; taxable numeric; wt numeric; reg numeric; ct jsonb;
begin
 if p_month is null or p_month not between date '2025-01-01' and date '2025-11-01' or extract(day from p_month)<>1
 or p_basic is null or p_basic<=0 or p_basic>1000000000 or p_basic<>round(p_basic,2)
 or p_premium is null or p_premium<0 or p_premium>1000000000 or p_premium<>round(p_premium,2)
 or p_cumulative is null or p_prior_taxable is null or p_prior_taxable<0 or p_prior_taxable>1000000000 or p_prior_taxable<>round(p_prior_taxable,2)
 or p_prior_withheld is null or p_prior_withheld<0 or p_prior_withheld>1000000000 or p_prior_withheld<>round(p_prior_withheld,2)
 or p_periods is null or p_periods not between 1 and 12
 then raise exception 'unsupported monetary inputs' using errcode='22023'; end if;
 gross:=p_basic+p_premium;
 if p_sss is distinct from gross or p_ph is distinct from p_basic or p_hdmf is distinct from p_basic then raise exception 'agency bases do not reconcile to supported pay scope' using errcode='P0001'; end if;
 s:=app.ph_contribution_candidate('sss',p_sss,p_month);
 h:=app.ph_contribution_candidate('philhealth',p_ph,p_month);
 f:=app.ph_contribution_candidate('pagibig',p_hdmf,p_month);
 ee:=(s->>'employee')::numeric+(h->>'employee')::numeric+(f->>'employee')::numeric;
 er:=(s->>'employer')::numeric+(h->>'employer')::numeric+(f->>'employer')::numeric;
 reg:=p_basic-ee; taxable:=gross-ee;
 if reg<0 then raise exception 'negative taxable regular compensation requires review' using errcode='P0001'; end if;
 p_cumulative:=p_cumulative or (reg<20833 and p_premium>0) or (p_premium>=reg and p_premium>0);
 if p_cumulative then
 ct:=app.ph_cumulative_tax(p_prior_taxable+taxable,p_periods,p_prior_withheld,'monthly',p_month);
 wt:=(ct->>'withholding')::numeric;
 else wt:=app.ph_tax_candidate(taxable,'monthly',p_month); end if;
 if gross-ee-wt<0 then raise exception 'insufficient compensation for withholding; review required' using errcode='P0001'; end if;
 return jsonb_build_object('basic',p_basic,'premium',p_premium,'gross',gross,'employeeContrib',ee,'employerContrib',er,'taxable',taxable,
 'withholding',wt,'net',gross-ee-wt,'employerCost',gross+er,'sss',s,'philhealth',h,'pagibig',f,'cumulative',p_cumulative,'averageEvidence',ct);
end $$;

-- No caller-provided amounts or attendance in the posting function. Read only
-- reviewed context, exact locked evidence, and immutable prior monthly snapshots.
create function app.ph_post_month(p_org uuid,p_user uuid,p_month date)
returns jsonb language plpgsql set search_path='' as $$
declare c app.ph_month_context; h app.ph_employment_history; actual_h app.ph_employment_history; old app.ph_money_snapshot;
 d date; last_day date; ev app.ph_workday_evidence; snap app.accounting_locked_snapshot;
 rate numeric; premium numeric:=0; line jsonb; exact_lines jsonb:='[]'; factor numeric; secs numeric; code text;
 prior_tax numeric:=0; prior_wt numeric:=0; prior_count int:=0; prev_count int:=0; prev_tax numeric:=0; prev_wt numeric:=0;
 sticky boolean:=false; j jsonb; s jsonb; ph jsonb; f jsonb; n int; journal_bal numeric;
begin
 perform app.accounting_tenant_lock(p_org);
 if auth.uid() is null or auth.uid()=p_user or not app.has_permission(p_org,'payroll.prepare') or not app.has_permission(p_org,'timesheet.lock') then raise exception 'forbidden' using errcode='42501'; end if;
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
revoke all on function app.ph_prepare_month(uuid,uuid,date,date,numeric,numeric,numeric,numeric,numeric,text),
app.ph_review_month(uuid,uuid,date,text),app.ph_month_amounts(numeric,numeric,date,numeric,numeric,numeric,numeric,numeric,int,boolean),
app.ph_post_month(uuid,uuid,date) from public,anon,authenticated,service_role;

-- A new previous-employer certificate after a posted month changes cumulative tax.
-- Until reviewed reversal/replay exists, reject such changes rather than rewrite history.
create function app.ph_guard_2316_after_post() returns trigger
language plpgsql set search_path='' as $$
declare i app.ph_2316_import;
begin
 if tg_table_name='ph_2316_import' then
  if exists(select 1 from app.ph_money_snapshot s where s.organization_id=new.organization_id and s.user_id=new.user_id and extract(year from s.pay_month)=new.tax_year)
  then raise exception 'posted tax year requires reviewed correction' using errcode='42501'; end if;
 else
  select * into i from app.ph_2316_import where id=new.import_id;
  if not found then raise exception 'missing certificate' using errcode='P0001'; end if;
  perform app.accounting_tenant_lock(i.organization_id);
  if exists(select 1 from app.ph_money_snapshot s where s.organization_id=i.organization_id and s.user_id=i.user_id and extract(year from s.pay_month)=i.tax_year)
  then raise exception 'posted tax year requires reviewed correction' using errcode='42501'; end if;
 end if;
 return new;
end $$;
create trigger ph_2316_post_guard before insert on app.ph_2316_import for each row execute function app.ph_guard_2316_after_post();
create trigger ph_2316_review_post_guard before insert on app.ph_2316_review for each row execute function app.ph_guard_2316_after_post();
revoke all on function app.ph_guard_2316_after_post() from public,anon,authenticated,service_role;

-- Minute-only adjustments cannot silently alter a posted monetary month.
-- A separate authorized reversal/replay workflow is required before such a change.
create function app.ph_guard_adjustment_after_money() returns trigger
language plpgsql set search_path='' as $$
declare a app.accounting_adjustment_proposal;
begin
 if tg_table_name='accounting_adjustment_proposal' then
  a:=new;
 else
  select * into a from app.accounting_adjustment_proposal where id=new.proposal_id;
  if not found then raise exception 'missing adjustment proposal' using errcode='P0001'; end if;
 end if;
 perform app.accounting_tenant_lock(a.organization_id);
 if exists(select 1 from app.ph_money_snapshot s where s.organization_id=a.organization_id and s.user_id=a.user_id
 and a.period_start< (s.pay_month+interval '1 month')::date and a.period_start+7>=s.pay_month)
 then raise exception 'posted monetary month requires authorized reversal' using errcode='42501'; end if;
 return new;
end $$;
create trigger ph_adjustment_post_guard before insert on app.accounting_adjustment_proposal for each row execute function app.ph_guard_adjustment_after_money();
create trigger ph_adjustment_decision_post_guard before insert on app.accounting_adjustment_decision for each row execute function app.ph_guard_adjustment_after_money();
revoke all on function app.ph_guard_adjustment_after_money() from public,anon,authenticated,service_role;
