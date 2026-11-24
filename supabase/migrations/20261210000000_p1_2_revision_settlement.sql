
-- Staging only: evolve the existing canonical immutable ledger.
alter table app.ph_monetary_snapshot add column revision int not null default 1 check(revision in (1,2));
alter table app.ph_payroll_journal add column revision int not null default 1 check(revision in (1,2));
alter table app.ph_canonical_reversal add column original_revision int generated always as (1) stored;
alter table app.ph_annual_settlement add column final_revision int not null default 1 check(final_revision in (1,2));
do $$ declare r record;begin
 for r in select conrelid::regclass t,conname from pg_constraint where contype='f' and confrelid='app.ph_monetary_snapshot'::regclass
 loop execute format('alter table %s drop constraint %I',r.t,r.conname);end loop;
end $$;
alter table app.ph_payroll_journal drop constraint ph_payroll_journal_pkey;
alter table app.ph_monetary_snapshot drop constraint ph_monetary_snapshot_pkey;
alter table app.ph_monetary_snapshot add primary key(organization_id,period_start,user_id,revision);
alter table app.ph_payroll_journal add primary key(organization_id,period_start,user_id,revision);
alter table app.ph_payroll_journal add foreign key(organization_id,period_start,user_id,revision) references app.ph_monetary_snapshot;
alter table app.ph_canonical_reversal add foreign key(organization_id,period_start,user_id,original_revision) references app.ph_monetary_snapshot;
alter table app.ph_annual_settlement add foreign key(organization_id,final_period,user_id,final_revision) references app.ph_monetary_snapshot;
alter table app.ph_monetary_snapshot add check(revision=1 or frequency in ('daily','semi-monthly'));
create view app.ph_effective_monetary with (security_invoker=true) as
 select s.* from app.ph_monetary_snapshot s where s.revision=2 or not exists(select 1 from app.ph_canonical_reversal r where (r.organization_id,r.period_start,r.user_id)=(s.organization_id,s.period_start,s.user_id));
revoke all on app.ph_effective_monetary from public,anon,authenticated,service_role;
alter table app.ph_payroll_attestation drop constraint ph_payroll_attestation_kind_check;
alter table app.ph_payroll_attestation add check(kind in ('opening','month','divisor','week','annual','salary_month','settlement_journal','custody_policy','statutory_quote','cutoff_opening','period','wage','contribution','reversal','entitlement','replay'));
create function app.ph_unresolved_reversal(p_org uuid,p_user uuid) returns boolean language sql stable set search_path='' as $$
 select exists(select 1 from app.ph_canonical_reversal r where r.organization_id=p_org and (p_user is null or r.user_id=p_user)
 and not exists(select 1 from app.ph_monetary_snapshot s where (s.organization_id,s.period_start,s.user_id,s.revision)=(r.organization_id,r.period_start,r.user_id,2)))
$$;
create or replace function app.ph_guard_period_overlap() returns trigger language plpgsql set search_path='' as $$
declare o app.ph_monetary_snapshot;a app.ph_payroll_attestation;
begin
 perform app.accounting_tenant_lock(new.organization_id);
 if exists(select 1 from app.ph_annual_settlement x where x.organization_id=new.organization_id and x.user_id=new.user_id and x.tax_year=extract(year from new.pay_date)) then raise exception 'closed year' using errcode='P0001';end if;
 if new.revision=2 then
 select * into o from app.ph_monetary_snapshot where (organization_id,period_start,user_id,revision)=(new.organization_id,new.period_start,new.user_id,1);
 if not found or (o.frequency,o.pay_date) is distinct from (new.frequency,new.pay_date)
 or not exists(select 1 from app.ph_canonical_reversal r where (r.organization_id,r.period_start,r.user_id)=(new.organization_id,new.period_start,new.user_id))
 or exists(select 1 from app.ph_monetary_snapshot x where x.organization_id=new.organization_id and x.user_id=new.user_id and x.period_start>new.period_start)
 then raise exception 'latest reversed original required' using errcode='P0001';end if;
 a:=app.ph_approved_evidence(new.organization_id,new.user_id,'replay',new.period_start);
 if new.evidence->>'attestation' is distinct from a.id::text or a.payload->>'originalAttestation' is distinct from o.evidence->>'attestation' then raise exception 'replacement evidence mismatch' using errcode='P0001';end if;
 elsif app.ph_unresolved_reversal(new.organization_id,new.user_id) then raise exception 'reversed period requires controlled replay' using errcode='P0001';end if;
 if exists(select 1 from app.ph_monetary_snapshot s where s.organization_id=new.organization_id and s.user_id=new.user_id and extract(year from s.pay_date)=extract(year from new.pay_date)
 and (s.frequency<>new.frequency or (s.period_start<=new.pay_date and s.pay_date>=new.period_start))
 and not (new.revision=2 and s.revision=1 and s.period_start=new.period_start)) then raise exception 'overlapping payroll or frequency change' using errcode='P0001';end if;
 return new;
end $$;

create or replace function app.ph_approve_payroll_evidence(p_org uuid,p_id uuid,p_evidence text)
returns void language plpgsql set search_path='' as $$
declare a app.ph_payroll_attestation; h app.ph_employment_history; y jsonb; v numeric;
begin
 perform app.accounting_tenant_lock(p_org);
 if auth.uid() is null or not app.has_permission(p_org,'payroll.prepare') then raise exception 'forbidden' using errcode='42501'; end if;
 select * into a from app.ph_payroll_attestation where id=p_id and organization_id=p_org;
 if not found or auth.uid() in (a.maker,a.user_id) then raise exception 'independent checker required' using errcode='42501'; end if;
 y:=a.payload;
 case a.kind
 when 'wage' then
 if y->>'region' is null or y->>'region' not in ('NCR','CAR','I','II','III','IV-A','IV-B','V','VI','VII','VIII','IX','X','XI','XII','XIII','NIR','BARMM')
 or length(btrim(coalesce(y->>'locality','')))<2 or length(btrim(coalesce(y->>'sector','')))<2 or length(btrim(coalesce(y->>'coverage','')))<8
 or length(btrim(coalesce(y->>'site','')))<1 or length(btrim(coalesce(y->>'order','')))<1
 or coalesce(y->>'source','') !~ '^https://(nwpc[.]dole[.]gov[.]ph|mole[.]bangsamoro[.]gov[.]ph)/'
 or coalesce(y->>'documentSha256','') !~ '^[a-f0-9]{64}$'
 or (y->>'through')::date is null or (y->>'through')::date<a.scope_date or (y->>'through')::date>date '2026-11-24'
 or not app.ph_stat_money((y->>'dailyMinimum')::numeric) or (y->>'dailyMinimum')::numeric<=0
 then raise exception 'complete reviewed wage-order category and source required' using errcode='22023';end if;
 when 'cutoff_opening' then
 if a.scope_date<>date '2026-01-01' or y->>'frequency' is null or y->>'frequency' not in ('daily','semi-monthly')
 or (y->>'firstPeriod')::date is null or (y->>'firstPeriod')::date not between date '2026-01-06' and date '2026-11-24'
 or (y->>'currentStart')::date is distinct from (y->>'firstPeriod')::date
 or jsonb_typeof(y->'certificates') is distinct from 'array'
 or (y->>'previousPeriods')::integer is null or (y->>'previousPeriods')::integer<0
 or jsonb_typeof(y->'benefitOpening') is distinct from 'object'
 or y->>'completeCurrentYtd' is distinct from 'true'
 then raise exception 'complete reviewed opening required' using errcode='22023';end if;
 when 'period','replay' then
 if (y->>'end')::date is null or (y->>'end')::date<a.scope_date or (y->>'end')::date>date '2026-11-24'
 or y->>'frequency' is null or y->>'frequency' not in ('daily','semi-monthly')
 or y->>'coverage' is distinct from 'ordinary-covered-complete'
 or jsonb_typeof(y->'nonwork') is distinct from 'object'
 or jsonb_typeof(y->'benefitKeys') is distinct from 'array'
 or y->>'cumulative' is null or y->>'cumulative' not in ('true','false')
 or not app.ph_stat_money((y->>'taxDeductible')::numeric)
 or not app.ph_stat_money((y->>'taxableExtras')::numeric)
 or not app.ph_stat_money((y->>'hazardPay')::numeric)
 or ((y->>'hazardPay')::numeric>0 and length(btrim(coalesce(y->>'hazardEvidence','')))<8)
 then raise exception 'complete reviewed period evidence required' using errcode='22023';end if;
 if a.kind='replay' and (y->>'undispatched' is distinct from 'true' or length(btrim(coalesce(y->>'reason','')))<8 or (y->>'originalAttestation')::uuid is null) then raise exception 'reviewed replacement evidence required' using errcode='22023';end if;
 when 'contribution' then
 if extract(day from a.scope_date)<>1 or (y->>'allocationDate')::date is null or date_trunc('month',(y->>'allocationDate')::date)::date<>a.scope_date
 then raise exception 'monthly contribution allocation date required' using errcode='22023';end if;
 foreach v in array array[(y->>'sss')::numeric,(y->>'philhealth')::numeric,(y->>'pagibig')::numeric] loop
 if not app.ph_stat_money(v) or v<=0 then raise exception 'reviewed agency bases required' using errcode='22023';end if;end loop;
 when 'reversal' then
 if y->>'undispatched' is distinct from 'true' or length(btrim(coalesce(y->>'reason','')))<8 then raise exception 'reviewed undispatched reversal required' using errcode='22023'; end if;
 when 'entitlement' then
 if (y->>'quoteDate')::date is null or y->>'category' is distinct from 'thirteenth' or (y->>'payDate')::date is distinct from a.scope_date then raise exception 'reviewed thirteenth entitlement required' using errcode='22023'; end if;
 when 'opening' then
 if a.scope_date<>date '2026-01-01' or (y->>'method') is null or y->>'method' not in ('weekly','cumulative')
 or (y->>'previousPeriods')::int is null or (y->>'previousPeriods')::int not between 0 and 52
 or jsonb_typeof(y->'certificates') is distinct from 'array'
 or (y->>'currentStart')::date is null or extract(year from (y->>'currentStart')::date)<>2026
 or (y->>'firstPeriod')::date is null or (y->>'currentStart')::date>(y->>'firstPeriod')::date
 then raise exception 'invalid opening evidence' using errcode='22023'; end if;
 insert into app.ph_monetary_opening values(p_org,a.user_id,2026,(y->>'firstPeriod')::date,a.evidence,a.maker,auth.uid());
 when 'month' then
 insert into app.ph_monthly_basis_evidence values(p_org,a.user_id,a.scope_date,(y->>'sss')::numeric,(y->>'philhealth')::numeric,(y->>'pagibig')::numeric,(y->>'allocationPeriod')::date,a.evidence,a.maker,auth.uid());
 when 'divisor' then
 select * into h from app.ph_employment_history where organization_id=p_org and user_id=a.user_id
 and effective_on=a.scope_date and recorded_at=(y->>'recordedAt')::timestamptz and pay_basis='monthly';
 if not found then raise exception 'monthly employment revision required' using errcode='P0001'; end if;
 insert into app.ph_salary_divisor_evidence values(p_org,a.user_id,h.effective_on,h.recorded_at,(y->>'annualPaidDays')::numeric,a.evidence,a.maker,auth.uid());
 when 'week' then
 if extract(isodow from a.scope_date)<>1 or jsonb_typeof(y->'nonwork') is distinct from 'array'
 or jsonb_array_length(y->'nonwork')>7 or jsonb_typeof(y->'supplemental') is distinct from 'array'
 or jsonb_array_length(y->'supplemental')>50 or y->>'coverage' is distinct from 'ordinary-rank-and-file-taxable-complete'
 then raise exception 'invalid weekly coverage' using errcode='22023'; end if;
 when 'salary_month' then
 if extract(day from a.scope_date)<>1 or y->>'method' is distinct from 'full-calendar-month-no-unpaid-days' or (y->>'recordedAt')::timestamptz is null or (y->>'effectiveOn')::date is null then raise exception 'invalid salary coverage' using errcode='22023'; end if;
 when 'settlement_journal' then
 if y->>'treatment' is distinct from 'reviewed-recoverable-and-payable-accrual' or jsonb_typeof(y->'result') is distinct from 'object' then raise exception 'invalid settlement evidence' using errcode='22023'; end if;
 when 'custody_policy' then
 if (y->>'importId')::uuid is null or (y->>'retainUntil')::date is null or not isfinite((y->>'retainUntil')::date) or jsonb_typeof(y->'legalHold') is distinct from 'boolean' then raise exception 'invalid custody policy' using errcode='22023'; end if;
 when 'statutory_quote' then
 if y->>'category' is null or y->>'category' not in ('thirteenth','maternity','leave','special_women','separation','retirement') or jsonb_typeof(y->'eligible') is distinct from 'boolean' or (y->>'eligible')::boolean is distinct from true then raise exception 'reviewed eligibility required' using errcode='22023'; end if;
 when 'annual' then
 if y->>'reason' is null or y->>'reason' not in ('year_end','termination') or (y->>'available')::numeric is null
 or (y->>'available')::numeric<0 or (y->>'available')::numeric<>round((y->>'available')::numeric,2)
 then raise exception 'invalid annual evidence' using errcode='22023'; end if;
 end case;
 insert into app.ph_payroll_attestation_decision values(a.id,auth.uid(),p_evidence,clock_timestamp());
 insert into public.audit_events(organization_id,actor_id,action,entity,entity_id,data)
 values(p_org,auth.uid(),'accounting.ph_evidence_approved','attestation',a.id::text,jsonb_build_object('kind',a.kind));
end $$;
create function app.ph_post_cutoff_version(p_org uuid,p_user uuid,p_start date,p_replay boolean)
returns jsonb language plpgsql set search_path='' as $$
declare a app.ph_payroll_attestation;o app.ph_payroll_attestation;wa app.ph_payroll_attestation;ca app.ph_payroll_attestation;
 h app.ph_employment_history; first_h app.ph_employment_history;ev app.ph_workday_evidence;z app.accounting_locked_snapshot;
 old app.ph_monetary_snapshot;y app.ph_benefit_year;b app.ph_benefit_event;original app.ph_monetary_snapshot; version_no int;
 freq text;e date;d date;wk date;mon date;alloc date;line jsonb;code text;nonwork jsonb;actual_ids jsonb;
 worked numeric;secs numeric;rate numeric;factor numeric;amount numeric;wage numeric;is_mwe boolean;any_mwe boolean:=false;any_non_mwe boolean:=false;
 basic numeric:=0;premium numeric:=0;qualifying numeric:=0;raw_basic numeric:=0;raw_premium numeric:=0;raw_exempt numeric:=0;
 extra numeric;hazard numeric;bg numeric:=0;be numeric:=0;gross numeric;exempt numeric;taxable numeric;ded numeric;ee numeric:=0;er numeric:=0;wt numeric;
 prior jsonb;pt numeric;pw numeric;n int;last_end date;sticky boolean;use_average boolean;avg_result jsonb;
 s jsonb;ph jsonb;f jsonb;contrib jsonb;calc jsonb;lines jsonb:='[]';bal numeric;regtax numeric;supptax numeric;
begin
 perform app.accounting_tenant_lock(p_org);
 if auth.uid() is null or auth.uid()=p_user or not app.has_permission(p_org,'payroll.prepare') or not app.has_permission(p_org,'timesheet.lock') then raise exception 'forbidden' using errcode='42501';end if;
 if p_start is null or p_start not between date '2026-01-06' and date '2026-11-24' then raise exception 'unsupported payroll date' using errcode='22023';end if;

 if p_replay is null then raise exception 'posting mode required' using errcode='22023';end if;
 version_no:=case when p_replay then 2 else 1 end;
 a:=app.ph_approved_evidence(p_org,p_user,case when p_replay then 'replay' else 'period' end,p_start);
 if a.maker=auth.uid() then raise exception 'maker cannot post' using errcode='42501';end if;
 if exists(select 1 from app.ph_annual_settlement where organization_id=p_org and user_id=p_user and tax_year=2026) then raise exception 'closed payroll' using errcode='P0001';end if;
 if p_replay then
 select * into original from app.ph_monetary_snapshot where organization_id=p_org and user_id=p_user and period_start=p_start and revision=1;
 if not found or original.frequency not in ('daily','semi-monthly') or a.payload->>'originalAttestation' is distinct from original.evidence->>'attestation'
 or not exists(select 1 from app.ph_canonical_reversal where organization_id=p_org and user_id=p_user and period_start=p_start)
 or exists(select 1 from app.ph_monetary_snapshot where organization_id=p_org and user_id=p_user and period_start>p_start)
 then raise exception 'latest reversed original required' using errcode='P0001';end if;
 if (a.payload - array['reason','undispatched','originalAttestation','taxableExtras']) is distinct from ((app.ph_approved_evidence(p_org,p_user,'period',p_start)).payload - 'taxableExtras') then raise exception 'unsupported replacement scope' using errcode='P0001';end if;
 else
 if app.ph_unresolved_reversal(p_org,p_user) or exists(select 1 from app.ph_monetary_snapshot where organization_id=p_org and user_id=p_user and period_start=p_start and revision=2) then raise exception 'reversed or replaced cutoff' using errcode='P0001';end if;
 end if;
 select * into old from app.ph_monetary_snapshot where organization_id=p_org and user_id=p_user and period_start=p_start and revision=version_no;
 if found then
 if old.evidence->>'attestation' is distinct from a.id::text then raise exception 'posting conflict' using errcode='P0001';end if;return old.evidence;end if;
 o:=app.ph_approved_evidence(p_org,p_user,'cutoff_opening','2026-01-01');
 freq:=o.payload->>'frequency';e:=app.ph_period_end(p_start,freq);
 if e>date '2026-11-24' or (a.payload->>'end')::date is distinct from e or a.payload->>'frequency' is distinct from freq then raise exception 'period or frequency mismatch' using errcode='22023';end if;
 -- Candidate pay date is end of cutoff. Frequency fixed for year; no overlap/gap.
 select count(*) filter(where m.gross>0)::int,coalesce(sum(m.taxable),0),coalesce(sum(m.withholding),0),max(m.pay_date),
 coalesce(bool_or((m.evidence->>'cumulative')::boolean),false)
 into n,pt,pw,last_end,sticky from app.ph_effective_monetary m
 where m.organization_id=p_org and m.user_id=p_user and extract(year from m.period_start)=2026 and m.period_start<p_start;
 if p_start is distinct from coalesce(last_end+1,(o.payload->>'firstPeriod')::date) then raise exception 'noncontiguous period history' using errcode='P0001';end if;
 if o.payload->'certificates' is distinct from '[]'::jsonb or (o.payload->>'previousPeriods')::int<>0 or exists(select 1 from app.ph_2316_import where organization_id=p_org and user_id=p_user and tax_year=2026) then raise exception 'cutoff prior employer requires integration' using errcode='P0001';end if;
 prior:=jsonb_build_object('taxable',0,'withheld',0,'periods',0);
 select * into y from app.ph_benefit_year where organization_id=p_org and user_id=p_user and tax_year=2026;
 if not found or y.opening_through>=(o.payload->>'firstPeriod')::date
 or o.payload->'benefitOpening' is distinct from jsonb_build_object('through',y.opening_through,'buckets',y.opening_buckets,'other',y.opening_other,'medicalMode',y.medical_mode)
 then raise exception 'reviewed benefit opening mismatch' using errcode='P0001';end if;
 if exists(select 1 from app.ph_benefit_event x where x.organization_id=p_org and x.user_id=p_user and x.tax_year=2026 and x.paid_on<p_start
 and not exists(select 1 from app.ph_effective_monetary m where m.organization_id=p_org and m.user_id=p_user and x.paid_on between m.period_start and m.pay_date))
 then raise exception 'earlier benefit not reconciled' using errcode='P0001';end if;
 -- Reject minute-only corrections and cross-period spill on either boundary.
 if exists(select 1 from app.accounting_adjustment_proposal q where q.organization_id=p_org and q.user_id=p_user and q.period_start<=e and q.period_start+6>=p_start)
 or exists(select 1 from app.accounting_locked_snapshot q cross join lateral jsonb_array_elements(q.reconciliation->'payLines') l
 where q.organization_id=p_org and q.user_id=p_user and
 (((l->>'workday')::date between p_start and e) is distinct from ((l->>'date')::date between p_start and e)))
 then raise exception 'adjustment or cross-cutoff workday requires allocation review' using errcode='P0001';end if;
 first_h:=app.ph_employment_as_of(p_org,p_user,p_start,clock_timestamp());
 if first_h.status<>'employed' then raise exception 'historically employed period required' using errcode='P0001';end if;
 if first_h.pay_basis not in ('daily','hourly') or freq not in ('daily','semi-monthly') then raise exception 'restricted cutoff compensation basis' using errcode='P0001';end if;
 for d in select p_start+i from generate_series(0,e-p_start)i loop
 wk:=d-(extract(isodow from d)::int-1);
 select * into ev from app.ph_workday_evidence where organization_id=p_org and user_id=p_user and work_date=d and period_start=wk;
 if not found then raise exception 'complete workday evidence required' using errcode='P0001';end if;
 h:=app.ph_employment_as_of(p_org,p_user,d,clock_timestamp());
 if h.status<>'employed' or (h.effective_on,h.recorded_at) is distinct from (ev.employment_effective_on,ev.employment_recorded_at)
 or h.pay_basis<>first_h.pay_basis or (h.pay_basis='monthly' and (h.effective_on,h.recorded_at) is distinct from (first_h.effective_on,first_h.recorded_at))
 then raise exception 'employment revision requires review' using errcode='P0001';end if;
 wa:=app.ph_wage_on(p_org,p_user,d,h.site_reference,h.wage_order_reference);
 wage:=(wa.payload->>'dailyMinimum')::numeric;
 rate:=case h.pay_basis when 'hourly' then h.rate_php when 'daily' then h.rate_php/8 else null end;
 -- Compare without floating-point. Monthly MWE and unusual coverage require separate review.
 if rate*8<wage or (h.pay_basis='monthly' and rate*8<=wage) then raise exception 'wage underpayment or unsupported monthly MWE' using errcode='P0001';end if;
 is_mwe:=rate*8=wage;any_mwe:=any_mwe or is_mwe;any_non_mwe:=any_non_mwe or not is_mwe;
 select * into z from app.accounting_locked_snapshot where organization_id=p_org and user_id=p_user and period_start=wk;
 if not found or z.reconciliation->>'classificationVersion' is distinct from '4'
 or coalesce((z.reconciliation->>'exactOvertimeReviewSeconds')::numeric,1)<>0
 or not exists(select 1 from public.payroll_periods where organization_id=p_org and period_start=wk)
 then raise exception 'locked exact attendance required' using errcode='P0001';end if;
 worked:=0;
 for line in select l from jsonb_array_elements(z.reconciliation->'payLines') l where (l->>'workday')::date=d loop
 secs:=(line->>'seconds')::numeric;factor:=(line->>'multiplier')::numeric;code:=line->>'code';
 if secs is null or secs<=0 or secs>86400 or factor is null or factor<1 or factor>10 or code is null or code !~ '^(REG|RD|SH|SH_RD|RH|RH_RD|DH|DH_RD)(_OT)?(_ND)?$'
 then raise exception 'invalid exact pay line' using errcode='P0001';end if;
 if is_mwe and code !~ '^(REG|RH|RH_RD|DH|DH_RD)(_OT)?(_ND)?$' then raise exception 'MWE rest/special-day exemption needs separate review' using errcode='P0001';end if;
 worked:=worked+secs;
 if code~'(^|_)OT(_|$)' then
 amount:=rate*secs/3600*factor;raw_premium:=raw_premium+amount;
 else
 amount:=rate*secs/3600*factor;
 if h.pay_basis='monthly' then raw_premium:=raw_premium+rate*secs/3600*(factor-1);
 else raw_basic:=raw_basic+rate*secs/3600;raw_premium:=raw_premium+rate*secs/3600*(factor-1);end if;
 end if;
 if is_mwe then raw_exempt:=raw_exempt+amount;end if;
 lines:=lines||jsonb_build_array(line||jsonb_build_object('hourlyRate',rate,'wageEvidence',wa.id,'employmentRevision',h.recorded_at));
 end loop;
 if worked>86400 then raise exception 'invalid total workday seconds' using errcode='P0001';end if;
 nonwork:=a.payload->'nonwork'->d::text;
 if worked>0 and nonwork is not null then raise exception 'overlapping nonwork payment' using errcode='P0001';end if;
 if worked=0 then
 if nonwork is null or jsonb_typeof(nonwork)<>'object' or length(btrim(coalesce(nonwork->>'reference','')))<8 then raise exception 'zero-work date requires disposition' using errcode='P0001';end if;
 if nonwork->>'kind' not in ('paid_leave','paid_regular_holiday','unpaid_nonwork','monthly_covered') or nonwork->>'kind' is null then raise exception 'unsupported nonwork disposition' using errcode='22023';end if;
 if nonwork->>'kind'='paid_regular_holiday' and coalesce(ev.calendar_classes->>d::text,'') not in ('regular_holiday','regular_holiday_rest') then raise exception 'holiday evidence mismatch' using errcode='P0001';end if;
 if h.pay_basis='monthly' and nonwork->>'kind'<>'monthly_covered' then raise exception 'partial monthly salary requires separate review' using errcode='P0001';end if;
 if h.pay_basis<>'monthly' and nonwork->>'kind'='monthly_covered' then raise exception 'invalid monthly coverage' using errcode='P0001';end if;
 if nonwork->>'kind' in ('paid_leave','paid_regular_holiday') then
 if nonwork->>'kind'='paid_leave' then raise exception 'cutoff paid leave requires canonical allocation review' using errcode='P0001';end if;
 amount:=rate*8;raw_basic:=raw_basic+amount;if is_mwe then raw_exempt:=raw_exempt+amount;end if;
 end if;
 lines:=lines||jsonb_build_array(nonwork||jsonb_build_object('date',d,'wageEvidence',wa.id,'employmentRevision',h.recorded_at));
 end if;
 end loop;
 if any_mwe and any_non_mwe then raise exception 'MWE status changed within period' using errcode='P0001';end if;
 if exists(select 1 from jsonb_object_keys(a.payload->'nonwork') k where k::date not between p_start and e) then raise exception 'nonwork date outside cutoff' using errcode='22023';end if;
 if first_h.pay_basis='monthly' then
 if freq='monthly' then raw_basic:=first_h.rate_php;
 elsif extract(day from p_start)=1 then raw_basic:=round(first_h.rate_php/2,2);
 else raw_basic:=first_h.rate_php-round(first_h.rate_php/2,2);end if;end if;
 basic:=round(raw_basic,2);premium:=round(raw_basic+raw_premium,2)-basic;
 qualifying:=round(raw_exempt,2);
 extra:=(a.payload->>'taxableExtras')::numeric;hazard:=(a.payload->>'hazardPay')::numeric;
 for b in select * from app.ph_benefit_event where organization_id=p_org and user_id=p_user and tax_year=2026 and paid_on between p_start and e order by sequence_no loop
 bg:=bg+(b.result->>'gross')::numeric;be:=be+(b.result->>'gross')::numeric-(b.result->>'taxable')::numeric;
 lines:=lines||jsonb_build_array(jsonb_build_object('benefitEvent',b.event_key,'result',b.result));
 end loop;
 select coalesce(jsonb_agg(event_key order by event_key),'[]') into actual_ids from app.ph_benefit_event where organization_id=p_org and user_id=p_user and tax_year=2026 and paid_on between p_start and e;
 if actual_ids is distinct from a.payload->'benefitKeys' then raise exception 'reviewed benefit set changed' using errcode='P0001';end if;
 gross:=basic+premium+extra+hazard+bg;
 exempt:=qualifying+be+case when any_mwe then hazard else 0 end;
 -- Monthly contribution bases are independently reviewed and allocated once
 -- to an exact payment date; no estimated or repeated deduction. Pay-month
 -- boundaries use payment date, not shift start. Partial/employer exemptions unsupported.
 mon:=date_trunc('month',e)::date;ca:=app.ph_approved_evidence(p_org,p_user,'contribution',mon);
 alloc:=(ca.payload->>'allocationDate')::date;
 if e<alloc and date_trunc('month',app.ph_period_end(e+1,freq))::date<>mon
 then raise exception 'final monthly cutoff cannot leave contributions unallocated' using errcode='P0001';end if;
 if e>alloc and not exists(select 1 from app.ph_effective_monetary m where m.organization_id=p_org and m.user_id=p_user and m.pay_date=alloc and m.evidence->>'contributionEvidence'=ca.id::text)
 then raise exception 'monthly contribution allocation missed' using errcode='P0001';end if;
 if e=alloc then
 s:=app.ph_contribution_candidate('sss',(ca.payload->>'sss')::numeric,mon);
 ph:=app.ph_contribution_candidate('philhealth',(ca.payload->>'philhealth')::numeric,mon);
 f:=app.ph_contribution_candidate('pagibig',(ca.payload->>'pagibig')::numeric,mon);
 ee:=(s->>'employee')::numeric+(ph->>'employee')::numeric+(f->>'employee')::numeric;
 er:=(s->>'employer')::numeric+(ph->>'employer')::numeric+(f->>'employer')::numeric;
 end if;
 ded:=(a.payload->>'taxDeductible')::numeric;
 if ded>least(ee,gross-exempt) or (not any_mwe and ded<>least(ee,gross-exempt)) then raise exception 'tax-deductible statutory contributions require review' using errcode='P0001';end if;
 taxable:=gross-exempt-ded;
 -- Mandatory cumulative switch for supplemental pay at/above regular taxable,
 -- or when regular taxable is below the periodic floor; sticky for the year.
 regtax:=greatest(0,basic-qualifying-ded);
 supptax:=greatest(0,taxable-regtax);
 use_average:=sticky or (prior->>'periods')::int>0 or (a.payload->>'cumulative')::boolean
 or (supptax>0 and (supptax>=regtax or app.ph_tax_candidate(regtax,freq,e)=0));
 if gross=0 then wt:=0;
 elsif use_average then
 avg_result:=app.ph_cumulative_withholding(pt+taxable+(prior->>'taxable')::numeric,n+1+(prior->>'periods')::int,pw+(prior->>'withheld')::numeric,freq,e);
 wt:=(avg_result->>'withhold')::numeric;
 else wt:=app.ph_tax_candidate(taxable,freq,e);end if;
 if gross-ee-wt<0 then raise exception 'insufficient compensation; separate reviewed settlement required' using errcode='P0001';end if;
 calc:=jsonb_build_object('sourceVersion',2,'revision',version_no,'frequency',freq,'periodStart',p_start,'periodEnd',e,'payDate',e,'basic',basic,'premium',premium,
 'gross',gross,'exempt',exempt,'mweExempt',qualifying+case when any_mwe then hazard else 0 end,'employeeContrib',ee,'employerContrib',er,
 'taxDeductible',ded,'taxable',taxable,'withholding',wt,'net',gross-ee-wt,'employerCost',gross+er,'benefitKeys',actual_ids,
 'contributions',jsonb_build_object('sss',s,'philhealth',ph,'pagibig',f),'sss',s,'philhealth',ph,'pagibig',f,'contributionEvidence',ca.id,'priorEmployer',prior,'cumulative',use_average,'averageEvidence',avg_result,'lines',lines,'attestation',a.id);

 insert into app.ph_monetary_snapshot(organization_id,period_start,user_id,pay_date,gross,employee_contributions,employer_contributions,taxable,withholding,net,evidence,posted_by,exempt,frequency,tax_deductible,revision)
 values(p_org,p_start,p_user,e,gross,ee,er,taxable,wt,gross-ee-wt,calc,auth.uid(),exempt,freq,ded,version_no);
 lines:=jsonb_build_array(jsonb_build_object('account','wage_expense','debit',gross,'credit',0),
 jsonb_build_object('account','employer_contribution_expense','debit',er,'credit',0),
 jsonb_build_object('account','net_payable','debit',0,'credit',gross-ee-wt),
 jsonb_build_object('account','withholding_payable','debit',0,'credit',wt),
 jsonb_build_object('account','sss_payable','debit',0,'credit',coalesce((s->>'total')::numeric,0)),
 jsonb_build_object('account','philhealth_payable','debit',0,'credit',coalesce((ph->>'total')::numeric,0)),
 jsonb_build_object('account','pagibig_payable','debit',0,'credit',coalesce((f->>'total')::numeric,0)));
 select sum((x->>'debit')::numeric-(x->>'credit')::numeric) into bal from jsonb_array_elements(lines)x;
 if bal<>0 then raise exception 'unbalanced journal' using errcode='P0001';end if;
 insert into app.ph_payroll_journal values(p_org,p_start,p_user,lines,gross+er,gross+er,version_no);
 insert into public.audit_events(organization_id,actor_id,action,entity,entity_id,data)
 values(p_org,auth.uid(),case when p_replay then 'accounting.ph_cutoff_replayed' else 'accounting.ph_cutoff_posted' end,'membership',p_user::text,jsonb_build_object('periodStart',p_start,'periodEnd',e,'frequency',freq));
 return calc;
end $$;
create or replace function app.ph_post_canonical_reversal(p_org uuid,p_user uuid,p_start date) returns void
language plpgsql set search_path='' as $$
declare a app.ph_payroll_attestation; d app.ph_payroll_attestation_decision; s app.ph_monetary_snapshot; j app.ph_payroll_journal; inverse jsonb;
begin
 perform app.accounting_tenant_lock(p_org);
 if auth.uid() is null or auth.uid()=p_user or not app.has_permission(p_org,'payroll.prepare') or not app.has_permission(p_org,'timesheet.lock') then raise exception 'forbidden' using errcode='42501';end if;
 a:=app.ph_approved_evidence(p_org,p_user,'reversal',p_start);
 select * into d from app.ph_payroll_attestation_decision where attestation_id=a.id;
 if auth.uid()<>d.checker or auth.uid()=a.maker then raise exception 'checker must post reversal' using errcode='42501';end if;
 select * into s from app.ph_monetary_snapshot where organization_id=p_org and user_id=p_user and period_start=p_start and revision=1;
 if not found or exists(select 1 from app.ph_monetary_snapshot x where x.organization_id=p_org and x.user_id=p_user and x.period_start>p_start)
 or exists(select 1 from app.ph_month_report x where x.organization_id=p_org and x.month_start=date_trunc('month',s.pay_date)::date)
 or exists(select 1 from app.ph_annual_settlement x where x.organization_id=p_org and x.user_id=p_user and x.tax_year=extract(year from s.pay_date))
 then raise exception 'latest unreported unsettled accrual required' using errcode='P0001';end if;
 select * into strict j from app.ph_payroll_journal where organization_id=p_org and user_id=p_user and period_start=p_start and revision=1;
 select jsonb_agg(jsonb_build_object('account',x->>'account','debit',(x->>'credit')::numeric,'credit',(x->>'debit')::numeric) order by ord)
 into inverse from jsonb_array_elements(j.lines) with ordinality as v(x,ord);
 insert into app.ph_canonical_reversal(organization_id,period_start,user_id,proposed_by,approved_by,attestation_id,lines,debit_total,credit_total)
 values(p_org,p_start,p_user,a.maker,auth.uid(),a.id,inverse,j.credit_total,j.debit_total);
 insert into public.audit_events(organization_id,actor_id,action,entity,entity_id,data)
 values(p_org,auth.uid(),'accounting.ph_canonical_reversed','membership',p_user::text,jsonb_build_object('periodStart',p_start));
end $$;
create or replace function app.ph_guard_cutoff_closed() returns trigger language plpgsql set search_path='' as $$
begin
 perform app.accounting_tenant_lock(new.organization_id);
 if app.ph_unresolved_reversal(new.organization_id,null) then raise exception 'reversed accrual requires amended review' using errcode='P0001';end if;
 if tg_table_name='ph_annual_settlement' and exists(select 1 from app.ph_monetary_snapshot s where s.organization_id=new.organization_id and s.frequency<>'weekly') then raise exception 'cutoff annual settlement requires dedicated completeness review' using errcode='P0001';end if;
 return new;
end $$;
create or replace function app.ph_month_report_totals(p_org uuid,p_month date) returns jsonb
language plpgsql stable set search_path='' as $$
declare j jsonb; e date; sss numeric; ph numeric; pi numeric; tax numeric; annual_due numeric; opening app.ph_payroll_attestation; ca app.ph_payroll_attestation; a text; actual numeric; expected numeric; first_day date;
begin
 if p_month is null or extract(day from p_month)<>1 or extract(year from p_month)<>2026 or (p_month+interval '1 month')::date>date '2026-11-24' then raise exception 'closed supported month required' using errcode='22023'; end if;
 e:=(p_month+interval '1 month')::date;
 if app.ph_unresolved_reversal(p_org,null) then raise exception 'reversed accrual requires amended report' using errcode='P0001';end if;
 for opening in select x.* from app.ph_payroll_attestation x join app.ph_payroll_attestation_decision d on d.attestation_id=x.id where x.organization_id=p_org and x.kind='cutoff_opening' and (x.payload->>'firstPeriod')::date<e loop
 first_day:=greatest(p_month,(opening.payload->>'firstPeriod')::date);
 if not exists(select 1 from app.ph_effective_monetary s where s.organization_id=p_org and s.user_id=opening.user_id and s.frequency=opening.payload->>'frequency' and s.period_start=first_day)
 or not exists(select 1 from app.ph_effective_monetary s where s.organization_id=p_org and s.user_id=opening.user_id and s.frequency=opening.payload->>'frequency' and s.pay_date=e-1)
 or exists(select 1 from generate_series(first_day,e-1,interval '1 day') g where not exists(select 1 from app.ph_effective_monetary s where s.organization_id=p_org and s.user_id=opening.user_id and g::date between s.period_start and s.pay_date))
 then raise exception 'complete cutoff calendar required for agency report' using errcode='P0001';end if;
 ca:=app.ph_approved_evidence(p_org,opening.user_id,'contribution',p_month);
 foreach a in array array['sss','philhealth','pagibig'] loop
 expected:=(app.ph_contribution_candidate(a,(ca.payload->>a)::numeric,p_month)->>'total')::numeric;
 select coalesce(sum((s.evidence->'contributions'->a->>'total')::numeric),0) into actual from app.ph_effective_monetary s where s.organization_id=p_org and s.user_id=opening.user_id and s.pay_date>=p_month and s.pay_date<e and s.evidence->>'contributionEvidence'=ca.id::text;
 if actual<>expected then raise exception 'agency contribution allocation incomplete' using errcode='P0001';end if;
 end loop;
 end loop;
 if not exists(select 1 from app.ph_effective_monetary s where s.organization_id=p_org and s.pay_date>=p_month and s.pay_date<e)
 or exists(select 1 from app.accounting_locked_snapshot s where s.organization_id=p_org and s.period_start+6>=p_month and s.period_start+6<e and not exists(select 1 from app.ph_effective_monetary m where (m.organization_id,m.period_start,m.user_id)=(s.organization_id,s.period_start,s.user_id))
 and not exists(select 1 from app.ph_payroll_attestation x join app.ph_payroll_attestation_decision d on d.attestation_id=x.id where x.organization_id=s.organization_id and x.user_id=s.user_id and x.kind='cutoff_opening' and (x.payload->>'firstPeriod')::date<e))
 or exists(select 1 from app.ph_annual_settlement a where a.organization_id=p_org and a.final_period+6>=p_month and a.final_period+6<e and not exists(select 1 from app.ph_annual_journal j where (j.organization_id,j.user_id,j.tax_year)=(a.organization_id,a.user_id,a.tax_year)))
 then raise exception 'unposted locked payroll or settlement' using errcode='P0001'; end if;
 select coalesce(sum((s.evidence->'contributions'->'sss'->>'total')::numeric),0),coalesce(sum((s.evidence->'contributions'->'philhealth'->>'total')::numeric),0),coalesce(sum((s.evidence->'contributions'->'pagibig'->>'total')::numeric),0),sum(s.withholding)
 into sss,ph,pi,tax from app.ph_effective_monetary s where s.organization_id=p_org and s.pay_date>=p_month and s.pay_date<e;
 select coalesce(sum((a.result->>'employeeWithholding')::numeric+(a.result->>'employerAdvance')::numeric),0) into annual_due from app.ph_annual_settlement a join app.ph_annual_journal x using(organization_id,user_id,tax_year) where a.organization_id=p_org and a.final_period+6>=p_month and a.final_period+6<e;
 -- Refund receivables remain separate. No automatic offset against current BIR.
 return jsonb_build_object('sss',sss,'philhealth',ph,'pagibig',pi,'bir',tax+annual_due,'refundOffsetApplied',false);
end $$;
create or replace function app.ph_prepare_month_report(p_org uuid,p_month date,p_evidence text) returns void
language plpgsql set search_path='' as $$
declare totals jsonb; src jsonb;
begin
 perform app.accounting_tenant_lock(p_org);
 if auth.uid() is null or not app.has_permission(p_org,'payroll.prepare') then raise exception 'forbidden' using errcode='42501'; end if;
 totals:=app.ph_month_report_totals(p_org,p_month);
 select jsonb_agg(jsonb_build_object('period',period_start,'employee',user_id,'revision',revision) order by period_start,user_id) into src from app.ph_effective_monetary where organization_id=p_org and pay_date>=p_month and pay_date<(p_month+interval '1 month')::date;
 insert into app.ph_month_report(organization_id,month_start,totals,source_periods,prepared_by,evidence) values(p_org,p_month,totals,src,auth.uid(),p_evidence);
end $$;
create or replace function app.ph_review_month_report(p_org uuid,p_month date,p_evidence text) returns void
language plpgsql set search_path='' as $$
declare r app.ph_month_report; src jsonb;
begin
 perform app.accounting_tenant_lock(p_org);
 if auth.uid() is null or not app.has_permission(p_org,'payroll.prepare') then raise exception 'forbidden' using errcode='42501'; end if;
 select * into r from app.ph_month_report where organization_id=p_org and month_start=p_month;
 if not found or r.prepared_by=auth.uid() then raise exception 'independent report review required' using errcode='42501'; end if;
 select jsonb_agg(jsonb_build_object('period',period_start,'employee',user_id,'revision',revision) order by period_start,user_id) into src from app.ph_effective_monetary where organization_id=p_org and pay_date>=p_month and pay_date<(p_month+interval '1 month')::date;
 if r.totals is distinct from app.ph_month_report_totals(p_org,p_month) or r.source_periods is distinct from src then raise exception 'report source changed' using errcode='P0001'; end if;
 insert into app.ph_month_report_review values(p_org,p_month,auth.uid(),p_evidence);
end $$;
create or replace function app.ph_settle_reviewed_thirteenth(p_org uuid,p_user uuid,p_day date) returns jsonb
language plpgsql set search_path='' as $$
declare a app.ph_payroll_attestation; q app.ph_payroll_attestation; j jsonb; basic numeric; paid numeric; amount numeric; o app.ph_payroll_attestation; last_day date;
begin
 perform app.accounting_tenant_lock(p_org);
 if auth.uid() is null or auth.uid()=p_user or not app.has_permission(p_org,'payroll.prepare') or not app.has_permission(p_org,'timesheet.lock') then raise exception 'forbidden' using errcode='42501';end if;
 a:=app.ph_approved_evidence(p_org,p_user,'entitlement',p_day);
 if a.maker=auth.uid() then raise exception 'independent entitlement posting required' using errcode='42501';end if;
 q:=app.ph_approved_evidence(p_org,p_user,'statutory_quote',(a.payload->>'quoteDate')::date);
 if q.payload->>'category' is distinct from 'thirteenth' or (q.payload->>'maternity')::numeric is distinct from 0 or (q.payload->>'integratedBasic')::numeric is distinct from 0 then raise exception 'restricted entitlement scope' using errcode='P0001';end if;
 o:=app.ph_approved_evidence(p_org,p_user,'cutoff_opening','2026-01-01');
 select coalesce(sum((s.evidence->>'basic')::numeric),0),max(s.pay_date) into basic,last_day from app.ph_effective_monetary s where s.organization_id=p_org and s.user_id=p_user and extract(year from s.pay_date)=2026 and s.pay_date<p_day;
 if last_day is null or last_day<>p_day-1 or p_day<( (o.payload->>'firstPeriod')::date+interval '1 month')::date
 or app.ph_unresolved_reversal(p_org,p_user)
 or exists(select 1 from app.ph_monetary_snapshot where organization_id=p_org and user_id=p_user and (frequency='weekly' or pay_date>=p_day))
 then raise exception 'complete prior cutoff accruals required' using errcode='P0001';end if;
 if exists(select 1 from app.ph_annual_settlement where organization_id=p_org and user_id=p_user and tax_year=2026) then raise exception 'closed entitlement year' using errcode='P0001';end if;
 select coalesce(sum((x.result->>'gross')::numeric),0) into paid from app.ph_benefit_event x where x.organization_id=p_org and x.user_id=p_user and x.tax_year=2026 and x.request->>'code'='13th_month';
 if basic is distinct from (q.payload->>'basic')::numeric or paid is distinct from (q.payload->>'paid')::numeric then raise exception 'entitlement evidence differs from ledger' using errcode='P0001';end if;
 j:=app.ph_reviewed_statutory_quote(p_org,p_user,q.scope_date);
 amount:=(j->'result'->>'remaining')::numeric;
 if amount<=0 then raise exception 'no outstanding entitlement' using errcode='P0001';end if;
 perform app.ph_post_benefit(p_org,p_user,'entitlement-'||a.id::text,p_day,'13th_month',amount,null,null,a.evidence);
 return jsonb_build_object('benefitAccrualOnly',true,'amount',amount,'attestation',a.id);
end $$;

create or replace function app.ph_post_cutoff_2026(p_org uuid,p_user uuid,p_start date) returns jsonb language sql set search_path='' as $$select app.ph_post_cutoff_version(p_org,p_user,p_start,false)$$;
create function app.ph_replay_cutoff_2026(p_org uuid,p_user uuid,p_start date) returns jsonb language sql set search_path='' as $$select app.ph_post_cutoff_version(p_org,p_user,p_start,true)$$;
-- Controlled internal reconciliation CSV, not an agency upload schema.
create function app.ph_export_reviewed_month(p_org uuid,p_month date) returns jsonb language plpgsql set search_path='' as $$
declare r app.ph_month_report;a text;amount numeric;paid numeric;csv text;src jsonb;
begin
 perform app.accounting_tenant_lock(p_org);
 if auth.uid() is null or not app.has_permission(p_org,'payroll.prepare') then raise exception 'forbidden' using errcode='42501';end if;
 select x.* into r from app.ph_month_report x join app.ph_month_report_review y using(organization_id,month_start) where x.organization_id=p_org and x.month_start=p_month;
 if not found or r.totals is distinct from app.ph_month_report_totals(p_org,p_month) then raise exception 'reviewed current report required' using errcode='P0001';end if;
 select jsonb_agg(jsonb_build_object('period',period_start,'employee',user_id,'revision',revision) order by period_start,user_id) into src from app.ph_effective_monetary where organization_id=p_org and pay_date>=p_month and pay_date<(p_month+interval '1 month')::date;
 if src is distinct from r.source_periods then raise exception 'report source changed' using errcode='P0001';end if;
 csv:='month,agency,liability_php,reviewed_remitted_php,outstanding_php'||chr(10);
 foreach a in array array['bir','pagibig','philhealth','sss'] loop
 amount:=(r.totals->>a)::numeric;
 select coalesce(sum(x.amount),0) into paid from app.ph_remittance_receipt x join app.ph_remittance_journal j using(organization_id,agency,receipt_reference) where x.organization_id=p_org and x.month_start=p_month and x.agency=a;
 if not app.ph_stat_money(amount) or not app.ph_stat_money(paid) or paid>amount then raise exception 'invalid report reconciliation' using errcode='P0001';end if;
 csv:=csv||to_char(p_month,'YYYY-MM')||','||a||','||to_char(amount,'FM999999999999999990.00')||','||to_char(paid,'FM999999999999999990.00')||','||to_char(amount-paid,'FM999999999999999990.00')||chr(10);
 end loop;
 insert into public.audit_events(organization_id,actor_id,action,entity,entity_id,data) values(p_org,auth.uid(),'accounting.ph_internal_report_export','month',p_month::text,jsonb_build_object('format','internal-reconciliation-v1'));
 return jsonb_build_object('format','internal-reconciliation-v1','officialFiling',false,'csv',csv,'sha256',encode(sha256(convert_to(csv,'UTF8')),'hex'));
end $$;
revoke all on function app.ph_unresolved_reversal(uuid,uuid),app.ph_post_cutoff_version(uuid,uuid,date,boolean),app.ph_replay_cutoff_2026(uuid,uuid,date),app.ph_export_reviewed_month(uuid,date) from public,anon,authenticated,service_role;
