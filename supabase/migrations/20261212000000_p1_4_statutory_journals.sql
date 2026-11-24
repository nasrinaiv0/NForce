
-- P1.4: immutable ancillary statutory journals, not a parallel payroll engine.
-- Only independently reviewed evidence; no external payment or agency submission.
alter table app.ph_payroll_attestation drop constraint ph_payroll_attestation_kind_check;
alter table app.ph_payroll_attestation add check(kind in ('opening','month','divisor','week','annual','salary_month','settlement_journal','custody_policy','statutory_quote','cutoff_opening','period','wage','contribution','reversal','entitlement','replay','cutoff_final','weekly_replay','form1601c','statutory_accrual','sss_reimbursement'));
create table app.ph_statutory_journal(
 organization_id uuid not null,user_id uuid not null,
 attestation_id uuid primary key references app.ph_payroll_attestation,
 quote_id uuid not null references app.ph_payroll_attestation,
 category text not null check(category in ('maternity_advance','sss_reimbursement','separation','retirement')),
 event_on date not null,covered_from date not null,covered_to date not null,
 source_digest text not null check(source_digest ~ '^[a-f0-9]{64}$'),
 result jsonb not null, lines jsonb not null check(jsonb_typeof(lines)='array'),
 debit_total numeric(18,2) not null,credit_total numeric(18,2) not null,
 recorded_by uuid not null references auth.users(id),recorded_at timestamptz not null default clock_timestamp(),
 foreign key(organization_id,user_id) references public.memberships(organization_id,user_id),
 unique(organization_id,source_digest),
 check(covered_from<=covered_to and debit_total=credit_total and debit_total>0)
);
create unique index ph_statutory_quote_once on app.ph_statutory_journal(quote_id) where category<>'sss_reimbursement';
create unique index ph_statutory_exit_once on app.ph_statutory_journal(organization_id,user_id) where category in ('separation','retirement');
alter table app.ph_statutory_journal enable row level security;
revoke all on app.ph_statutory_journal from public,anon,authenticated,service_role;
create trigger p14_statutory_immutable before update or delete on app.ph_statutory_journal for each row execute function app.forbid_mutation();
create trigger p14_statutory_barrier before insert on app.ph_statutory_journal for each row execute function app.accounting_write_barrier();

create function app.ph_statutory_lines(p_category text,p_amount numeric,p_differential numeric) returns jsonb
language plpgsql immutable set search_path='' as $$
begin
 if not app.ph_stat_money(p_amount) or p_amount<=0 or not app.ph_stat_money(p_differential) then raise exception 'invalid statutory amount' using errcode='22023';end if;
 case p_category
 when 'maternity_advance' then
 return jsonb_build_array(jsonb_build_object('account','sss_maternity_receivable','debit',p_amount,'credit',0),jsonb_build_object('account','maternity_differential_expense','debit',p_differential,'credit',0),jsonb_build_object('account','verified_disbursement_clearing','debit',0,'credit',p_amount+p_differential));
 when 'sss_reimbursement' then
 if p_differential<>0 then raise exception 'unexpected differential' using errcode='22023';end if;
 return jsonb_build_array(jsonb_build_object('account','verified_receipt_clearing','debit',p_amount,'credit',0),jsonb_build_object('account','sss_maternity_receivable','debit',0,'credit',p_amount));
 when 'separation','retirement' then
 if p_differential<>0 then raise exception 'unexpected differential' using errcode='22023';end if;
 return jsonb_build_array(jsonb_build_object('account',p_category||'_expense','debit',p_amount,'credit',0),jsonb_build_object('account','statutory_exit_payable','debit',0,'credit',p_amount));
 else raise exception 'unsupported statutory event' using errcode='22023';
 end case;
end $$;

create function app.ph_post_statutory_journal(p_org uuid,p_user uuid,p_day date,p_kind text) returns jsonb
language plpgsql set search_path='' as $$
declare a app.ph_payroll_attestation;q app.ph_payroll_attestation;old app.ph_statutory_journal;adv app.ph_statutory_journal;h app.ph_employment_history;
 s app.ph_monetary_snapshot;y jsonb;j jsonb;lines jsonb;v_category text;from_day date;to_day date;amount numeric;differential numeric:=0;received numeric;dt numeric;ct numeric;
begin
 perform app.accounting_tenant_lock(p_org);
 if auth.uid() is null or auth.uid()=p_user or not app.has_permission(p_org,'payroll.prepare') or not app.has_permission(p_org,'timesheet.lock') then raise exception 'forbidden' using errcode='42501';end if;
 if p_kind not in ('statutory_accrual','sss_reimbursement') or p_day is null or p_day not between date '2026-01-06' and date '2026-11-24' then raise exception 'unsupported event scope' using errcode='22023';end if;
 a:=app.ph_approved_evidence(p_org,p_user,p_kind,p_day);
 if a.maker=auth.uid() then raise exception 'independent statutory posting required' using errcode='42501';end if;
 y:=a.payload;
 select * into old from app.ph_statutory_journal where attestation_id=a.id;
 if found then return old.result;end if;
 q:=app.ph_approved_evidence(p_org,p_user,'statutory_quote',(y->>'quoteDate')::date);
 if q.id::text is distinct from y->>'quoteId' then raise exception 'exact reviewed quote required' using errcode='P0001';end if;
 if p_kind='sss_reimbursement' then
 select * into adv from app.ph_statutory_journal where organization_id=p_org and user_id=p_user and quote_id=q.id and category='maternity_advance';
 if not found or p_day<adv.event_on then raise exception 'verified original maternity advance required' using errcode='P0001';end if;
 amount:=(y->>'amount')::numeric;
 select coalesce(sum((x.result->>'amount')::numeric),0) into received from app.ph_statutory_journal x where x.organization_id=p_org and x.quote_id=q.id and x.category='sss_reimbursement';
 if received+amount>(adv.result->>'sssAdvance')::numeric then raise exception 'reimbursement exceeds verified advance' using errcode='P0001';end if;
 v_category:='sss_reimbursement';from_day:=adv.covered_from;to_day:=adv.covered_to;
 j:=jsonb_build_object('amount',amount,'cumulativeReimbursed',received+amount,'outstanding',(adv.result->>'sssAdvance')::numeric-received-amount);
 else
 if app.ph_unresolved_reversal(p_org,p_user) or exists(select 1 from app.ph_annual_settlement where organization_id=p_org and user_id=p_user and tax_year=2026) then raise exception 'unresolved or closed payroll' using errcode='P0001';end if;
 if exists(select 1 from app.ph_statutory_journal where quote_id=q.id) then raise exception 'statutory quote already consumed' using errcode='P0001';end if;
 j:=app.ph_reviewed_statutory_quote(p_org,p_user,q.scope_date)->'result';
 if q.payload->>'category' is distinct from y->>'category' then raise exception 'quote category mismatch' using errcode='P0001';end if;
 case y->>'category'
 when 'maternity' then
 v_category:='maternity_advance';from_day:=(y->>'coveredFrom')::date;to_day:=(y->>'coveredTo')::date;
 amount:=(j->>'sssAdvance')::numeric;differential:=(j->>'salaryDifferential')::numeric;
 if to_day-from_day+1<>(j->>'paidDays')::int or from_day>p_day or to_day>date '2026-11-24'
 or amount+differential is distinct from (y->>'employeePaid')::numeric
 or (j->>'fullPay')::numeric-(j->>'employeeContributions')::numeric<amount
 or exists(select 1 from app.ph_monetary_snapshot ms where ms.organization_id=p_org and ms.user_id=p_user and ms.period_start<=to_day and ms.pay_date>=from_day)
 or exists(select 1 from app.ph_statutory_journal x where x.organization_id=p_org and x.user_id=p_user and x.category='maternity_advance' and x.covered_from<=to_day and x.covered_to>=from_day)
 then raise exception 'maternity payment or overlapping coverage needs reconciliation' using errcode='P0001';end if;
 j:=j||jsonb_build_object('employeePaid',amount+differential,'incomeTaxExempt',amount+differential,'agencyContributionsExternalReview',true);
 when 'separation','retirement' then
 v_category:=y->>'category';from_day:=(y->>'exitDate')::date;to_day:=from_day;amount:=(j->>'minimum')::numeric;
 select * into s from app.ph_effective_monetary where organization_id=p_org and user_id=p_user order by pay_date desc limit 1;
 if not found or s.pay_date+1<>from_day or p_day<from_day or (y->>'finalPeriod')::date is distinct from s.period_start or (y->>'finalRevision')::int is distinct from s.revision
 or not exists(select 1 from public.memberships where organization_id=p_org and user_id=p_user and status='ended') then raise exception 'latest effective final period and ended membership required' using errcode='P0001';end if;
 h:=app.ph_employment_as_of(p_org,p_user,from_day,clock_timestamp());
 if h.status is distinct from 'separated' or h.effective_on is distinct from from_day then raise exception 'exact separation history required' using errcode='P0001';end if;
 if (y->>'approvedEntitlement')::numeric is distinct from amount then raise exception 'approved minimum differs from calculation' using errcode='P0001';end if;
 j:=j||jsonb_build_object('amount',amount,'reviewedTaxExemption',true,'finalPeriod',s.period_start,'finalRevision',s.revision);
 else raise exception 'unsupported statutory accrual' using errcode='22023';
 end case;
 if exists(select 1 from app.ph_month_report r where r.organization_id=p_org and r.month_start<=date_trunc('month',greatest(to_day,p_day))::date and r.month_start>=date_trunc('month',least(from_day,p_day))::date) then raise exception 'closed report requires amended reconciliation' using errcode='P0001';end if;
 end if;
 lines:=app.ph_statutory_lines(v_category,amount,differential);
 select sum((x->>'debit')::numeric),sum((x->>'credit')::numeric) into dt,ct from jsonb_array_elements(lines)x;
 if dt<>ct or dt<=0 then raise exception 'unbalanced statutory journal' using errcode='P0001';end if;
 j:=j||jsonb_build_object('category',v_category,'journalTotal',dt,'candidateOnly',true,'paymentInitiated',false);
 insert into app.ph_statutory_journal(organization_id,user_id,attestation_id,quote_id,category,event_on,covered_from,covered_to,source_digest,result,lines,debit_total,credit_total,recorded_by)
 values(p_org,p_user,a.id,q.id,v_category,p_day,from_day,to_day,y->>'sourceDigest',j,lines,dt,ct,auth.uid());
 insert into public.audit_events(organization_id,actor_id,action,entity,entity_id,data)
 values(p_org,auth.uid(),'accounting.ph_statutory_journal','attestation',a.id::text,jsonb_build_object('category',category));
 return j;
end $$;

-- Do not silently omit ancillary compensation from ordinary gross-to-net, 13th
-- month, annual close, or agency reporting. Explicit integration still needed.
create function app.ph_guard_statutory_overlap() returns trigger language plpgsql set search_path='' as $$
begin
 perform app.accounting_tenant_lock(new.organization_id);
 if exists(select 1 from app.ph_statutory_journal j where j.organization_id=new.organization_id and j.user_id=new.user_id and
 ((j.category='maternity_advance' and j.covered_from<=new.pay_date and j.covered_to>=new.period_start) or (j.category in ('separation','retirement') and new.pay_date>=j.covered_from))) then raise exception 'statutory compensation requires integrated reconciliation' using errcode='P0001';end if;
 return new;
end $$;
create trigger p14_statutory_overlap before insert on app.ph_monetary_snapshot for each row execute function app.ph_guard_statutory_overlap();
create function app.ph_guard_statutory_final() returns trigger language plpgsql set search_path='' as $$
begin
 perform app.accounting_tenant_lock(new.organization_id);
 if exists(select 1 from app.ph_statutory_journal where organization_id=new.organization_id and user_id=new.user_id and category<>'sss_reimbursement') then raise exception 'statutory final compensation requires integrated reconciliation' using errcode='P0001';end if;
 return new;
end $$;
create trigger p14_statutory_final before insert on app.ph_annual_settlement for each row execute function app.ph_guard_statutory_final();

-- Historical reconciliation reads original, inverse and effective replacement.
-- It does not mutate historical payroll or recalculate downstream tax.
create function app.ph_reconcile_corrected_period(p_org uuid,p_user uuid,p_start date) returns jsonb
language plpgsql set search_path='' as $$
declare o app.ph_monetary_snapshot;n app.ph_monetary_snapshot;j app.ph_payroll_journal;k app.ph_payroll_journal;r app.ph_canonical_reversal;delta jsonb;bad boolean;
begin
 perform app.accounting_tenant_lock(p_org);
 if auth.uid() is null or auth.uid()=p_user or not app.has_permission(p_org,'payroll.prepare') then raise exception 'forbidden' using errcode='42501';end if;
 select * into o from app.ph_monetary_snapshot where (organization_id,user_id,period_start,revision)=(p_org,p_user,p_start,1);
 select * into n from app.ph_effective_monetary where (organization_id,user_id,period_start,revision)=(p_org,p_user,p_start,2);
 if o.revision is null or n.revision is null then raise exception 'complete corrected period required' using errcode='P0001';end if;
 select * into strict j from app.ph_payroll_journal where (organization_id,user_id,period_start,revision)=(p_org,p_user,p_start,1);
 select * into strict k from app.ph_payroll_journal where (organization_id,user_id,period_start,revision)=(p_org,p_user,p_start,2);
 select * into strict r from app.ph_canonical_reversal where (organization_id,user_id,period_start)=(p_org,p_user,p_start);
 select exists(select 1 from (select x->>'account' a,sum((x->>'debit')::numeric-(x->>'credit')::numeric) v from jsonb_array_elements(j.lines||r.lines)x group by 1) z where v<>0) into bad;
 if bad or j.debit_total<>o.gross+o.employer_contributions or k.debit_total<>n.gross+n.employer_contributions
 or r.debit_total<>j.credit_total or r.credit_total<>j.debit_total
 or exists(select 1 from (values(j.lines,j.debit_total,j.credit_total),(k.lines,k.debit_total,k.credit_total),(r.lines,r.debit_total,r.credit_total)) z(lines,d,c) where d<>(select sum((x->>'debit')::numeric) from jsonb_array_elements(z.lines)x) or c<>(select sum((x->>'credit')::numeric) from jsonb_array_elements(z.lines)x))
 then raise exception 'historical journal mismatch' using errcode='P0001';end if;
 select jsonb_object_agg(a,v) into delta from (select x->>'account' a,sum((x->>'debit')::numeric-(x->>'credit')::numeric) v from jsonb_array_elements(r.lines||k.lines)x group by 1) z;
 return jsonb_build_object('originalRevision',1,'effectiveRevision',2,'grossDelta',n.gross-o.gross,'netDelta',n.net-o.net,'withholdingDelta',n.withholding-o.withholding,'accountDelta',delta,'historicalRewrite',false);
end $$;

-- Portal-specific preparation packet from the already reviewed internal report.
-- No agency identifier, guessed file schema, upload or submission.
create function app.ph_agency_preparation_packet(p_org uuid,p_month date,p_agency text) returns jsonb
language plpgsql set search_path='' as $$
declare x jsonb;r app.ph_month_report;ee numeric;er numeric;due numeric;paid numeric;label text;
begin
 perform app.accounting_tenant_lock(p_org);
 if auth.uid() is null or not app.has_permission(p_org,'payroll.prepare') then raise exception 'forbidden' using errcode='42501';end if;
 if p_agency not in ('sss','philhealth','pagibig') or p_agency is null then raise exception 'use reviewed BIR worksheet for tax' using errcode='22023';end if;
 x:=app.ph_export_reviewed_month(p_org,p_month);
 select * into strict r from app.ph_month_report where organization_id=p_org and month_start=p_month;
 select coalesce(sum((s.evidence->'contributions'->p_agency->>'employee')::numeric),0),coalesce(sum((s.evidence->'contributions'->p_agency->>'employer')::numeric),0)
 into ee,er from app.ph_effective_monetary s where s.organization_id=p_org and s.pay_date>=p_month and s.pay_date<(p_month+interval '1 month')::date;
 due:=(r.totals->>p_agency)::numeric;
 if ee+er<>due then raise exception 'agency component mismatch' using errcode='P0001';end if;
 select coalesce(sum(rr.amount),0) into paid from app.ph_remittance_receipt rr join app.ph_remittance_journal j using(organization_id,agency,receipt_reference) where rr.organization_id=p_org and rr.month_start=p_month and rr.agency=p_agency;
 label:=case p_agency when 'sss' then 'My.SSS e-CL / PRN' when 'philhealth' then 'EPRS / SPA' else 'Membership Savings Remittance Form' end;
 return jsonb_build_object('agency',p_agency,'month',p_month,'destination',label,'employee',ee,'employer',er,'liability',due,'reviewedRemitted',paid,'outstanding',due-paid,'sourceSha256',x->>'sha256','officialUpload',false);
end $$;
revoke all on function app.ph_statutory_lines(text,numeric,numeric),app.ph_post_statutory_journal(uuid,uuid,date,text),app.ph_guard_statutory_overlap(),app.ph_guard_statutory_final(),app.ph_reconcile_corrected_period(uuid,uuid,date),app.ph_agency_preparation_packet(uuid,date,text) from public,anon,authenticated,service_role;

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
 if a.scope_date<>date '2026-01-01' or y->>'frequency' is null or y->>'frequency' not in ('daily','semi-monthly','monthly')
 or (y->>'firstPeriod')::date is null or (y->>'firstPeriod')::date not between date '2026-01-06' and date '2026-11-24'
 or (y->>'currentStart')::date is distinct from (y->>'firstPeriod')::date
 or jsonb_typeof(y->'certificates') is distinct from 'array'
 or (y->>'previousPeriods')::integer is null or (y->>'previousPeriods')::integer<0
 or jsonb_typeof(y->'benefitOpening') is distinct from 'object'
 or y->>'completeCurrentYtd' is distinct from 'true'
 then raise exception 'complete reviewed opening required' using errcode='22023';end if;
 when 'period','replay' then
 if (y->>'end')::date is null or (y->>'end')::date<a.scope_date or (y->>'end')::date>date '2026-11-24'
 or y->>'frequency' is null or y->>'frequency' not in ('daily','semi-monthly','monthly')
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
 when 'cutoff_final' then
 if y->>'reason' is distinct from 'termination' or y->>'exitKind' is distinct from 'ordinary_resignation_no_severance' or y->>'undispatched' is distinct from 'true' or y->>'completeExitEntitlements' is distinct from 'true' or y->>'rankAndFileEligible' is distinct from 'true' or not app.ph_stat_money((y->>'available')::numeric) then raise exception 'restricted reviewed final compensation required' using errcode='22023';end if;
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
 when 'week','weekly_replay' then
 if extract(isodow from a.scope_date)<>1 or jsonb_typeof(y->'nonwork') is distinct from 'array'
 or jsonb_array_length(y->'nonwork')>7 or jsonb_typeof(y->'supplemental') is distinct from 'array'
 or jsonb_array_length(y->'supplemental')>50 or y->>'coverage' is distinct from 'ordinary-rank-and-file-taxable-complete'
 then raise exception 'invalid weekly coverage' using errcode='22023'; end if;
 if a.kind='weekly_replay' and (y->>'undispatched' is distinct from 'true' or length(btrim(coalesce(y->>'reason','')))<8 or (y->>'originalAttestation')::uuid is null) then raise exception 'reviewed weekly replacement required' using errcode='22023';end if;
 when 'form1601c' then
 if extract(day from a.scope_date)<>1 or y->>'version' is distinct from '1601-C-2018-ENCS' or jsonb_typeof(y->'items') is distinct from 'object' or y->>'paidCompensationVerified' is distinct from 'true' then raise exception 'reviewed form evidence required' using errcode='22023';end if;
 when 'salary_month' then
 if extract(day from a.scope_date)<>1 or y->>'method' is distinct from 'full-calendar-month-no-unpaid-days' or (y->>'recordedAt')::timestamptz is null or (y->>'effectiveOn')::date is null then raise exception 'invalid salary coverage' using errcode='22023'; end if;
 when 'settlement_journal' then
 if y->>'treatment' is distinct from 'reviewed-recoverable-and-payable-accrual' or jsonb_typeof(y->'result') is distinct from 'object' then raise exception 'invalid settlement evidence' using errcode='22023'; end if;
 when 'custody_policy' then
 if (y->>'importId')::uuid is null or (y->>'retainUntil')::date is null or not isfinite((y->>'retainUntil')::date) or jsonb_typeof(y->'legalHold') is distinct from 'boolean' then raise exception 'invalid custody policy' using errcode='22023'; end if;
 when 'statutory_quote' then
 if y->>'category' is null or y->>'category' not in ('thirteenth','maternity','leave','special_women','separation','retirement') or jsonb_typeof(y->'eligible') is distinct from 'boolean' or (y->>'eligible')::boolean is distinct from true then raise exception 'reviewed eligibility required' using errcode='22023'; end if;
 when 'statutory_accrual' then
 if coalesce(y->>'sourceDigest','') !~ '^[a-f0-9]{64}$' or (y->>'quoteId')::uuid is null or (y->>'quoteDate')::date is null or y->>'taxTreatmentVerified' is distinct from 'true' or y->>'noDuplicateCompensation' is distinct from 'true' then raise exception 'reviewed statutory source and tax treatment required' using errcode='22023';end if;
 case y->>'category'
 when 'maternity' then
 if y->>'actualPaymentVerified' is distinct from 'true' or y->>'nonExemptEmployer' is distinct from 'true' or y->>'contributionsReviewed' is distinct from 'true' or not app.ph_stat_money((y->>'employeePaid')::numeric)
 or (y->>'coveredFrom')::date is null or (y->>'coveredTo')::date is null or (y->>'coveredFrom')::date<date '2026-01-06' or (y->>'coveredTo')::date<(y->>'coveredFrom')::date then raise exception 'reviewed maternity advance evidence required' using errcode='22023';end if;
 when 'separation','retirement' then
 if y->>'statutoryMinimumOnly' is distinct from 'true' or y->>'taxExemptionVerified' is distinct from 'true' or length(btrim(coalesce(y->>'taxEvidenceReference','')))<8
 or (y->>'exitDate')::date is null or (y->>'finalPeriod')::date is null or (y->>'finalRevision')::int is null or not app.ph_stat_money((y->>'approvedEntitlement')::numeric) then raise exception 'reviewed exempt exit entitlement required' using errcode='22023';end if;
 else raise exception 'unsupported statutory category' using errcode='22023';
 end case;
 when 'sss_reimbursement' then
 if coalesce(y->>'sourceDigest','') !~ '^[a-f0-9]{64}$' or (y->>'quoteId')::uuid is null or (y->>'quoteDate')::date is null or y->>'receiptVerified' is distinct from 'true' or not app.ph_stat_money((y->>'amount')::numeric) or (y->>'amount')::numeric<=0 then raise exception 'reviewed reimbursement receipt required' using errcode='22023';end if;
 when 'annual' then
 if y->>'reason' is null or y->>'reason' not in ('year_end','termination') or (y->>'available')::numeric is null
 or (y->>'available')::numeric<0 or (y->>'available')::numeric<>round((y->>'available')::numeric,2)
 then raise exception 'invalid annual evidence' using errcode='22023'; end if;
 end case;
 insert into app.ph_payroll_attestation_decision values(a.id,auth.uid(),p_evidence,clock_timestamp());
 insert into public.audit_events(organization_id,actor_id,action,entity,entity_id,data)
 values(p_org,auth.uid(),'accounting.ph_evidence_approved','attestation',a.id::text,jsonb_build_object('kind',a.kind));
end $$;
create or replace function app.ph_month_report_totals(p_org uuid,p_month date) returns jsonb
language plpgsql stable set search_path='' as $$
declare j jsonb; e date; sss numeric; ph numeric; pi numeric; tax numeric; annual_due numeric; opening app.ph_payroll_attestation; ca app.ph_payroll_attestation; a text; actual numeric; expected numeric; first_day date;
begin
 if p_month is null or extract(day from p_month)<>1 or extract(year from p_month)<>2026 or (p_month+interval '1 month')::date>date '2026-11-24' then raise exception 'closed supported month required' using errcode='22023'; end if;
 e:=(p_month+interval '1 month')::date;
 if exists(select 1 from app.ph_statutory_journal x where x.organization_id=p_org and x.category<>'sss_reimbursement' and (x.event_on>=p_month and x.event_on<e or x.covered_from<e and x.covered_to>=p_month)) then raise exception 'statutory compensation requires reporting reconciliation' using errcode='P0001';end if;
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
 or exists(select 1 from app.ph_annual_settlement a where a.organization_id=p_org and (select es.pay_date from app.ph_effective_monetary es where (es.organization_id,es.period_start,es.user_id,es.revision)=(a.organization_id,a.final_period,a.user_id,a.final_revision))>=p_month and (select es.pay_date from app.ph_effective_monetary es where (es.organization_id,es.period_start,es.user_id,es.revision)=(a.organization_id,a.final_period,a.user_id,a.final_revision))<e and not exists(select 1 from app.ph_annual_journal j where (j.organization_id,j.user_id,j.tax_year)=(a.organization_id,a.user_id,a.tax_year)))
 then raise exception 'unposted locked payroll or settlement' using errcode='P0001'; end if;
 select coalesce(sum((s.evidence->'contributions'->'sss'->>'total')::numeric),0),coalesce(sum((s.evidence->'contributions'->'philhealth'->>'total')::numeric),0),coalesce(sum((s.evidence->'contributions'->'pagibig'->>'total')::numeric),0),sum(s.withholding)
 into sss,ph,pi,tax from app.ph_effective_monetary s where s.organization_id=p_org and s.pay_date>=p_month and s.pay_date<e;
 select coalesce(sum((a.result->>'employeeWithholding')::numeric+(a.result->>'employerAdvance')::numeric),0) into annual_due from app.ph_annual_settlement a join app.ph_annual_journal x using(organization_id,user_id,tax_year) where a.organization_id=p_org and (select es.pay_date from app.ph_effective_monetary es where (es.organization_id,es.period_start,es.user_id,es.revision)=(a.organization_id,a.final_period,a.user_id,a.final_revision))>=p_month and (select es.pay_date from app.ph_effective_monetary es where (es.organization_id,es.period_start,es.user_id,es.revision)=(a.organization_id,a.final_period,a.user_id,a.final_revision))<e;
 -- Refund receivables remain separate. No automatic offset against current BIR.
 return jsonb_build_object('sss',sss,'philhealth',ph,'pagibig',pi,'bir',tax+annual_due,'refundOffsetApplied',false);
end $$;
create or replace function app.ph_settle_reviewed_thirteenth(p_org uuid,p_user uuid,p_day date) returns jsonb
language plpgsql set search_path='' as $$
declare a app.ph_payroll_attestation; q app.ph_payroll_attestation; j jsonb; basic numeric; paid numeric; amount numeric; o app.ph_payroll_attestation; last_day date;
begin
 perform app.accounting_tenant_lock(p_org);
 if auth.uid() is null or auth.uid()=p_user or not app.has_permission(p_org,'payroll.prepare') or not app.has_permission(p_org,'timesheet.lock') then raise exception 'forbidden' using errcode='42501';end if;
 if exists(select 1 from app.ph_statutory_journal where organization_id=p_org and user_id=p_user and category='maternity_advance') then raise exception 'maternity differential requires integrated 13th review' using errcode='P0001';end if;
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
create or replace function app.ph_post_canonical_reversal(p_org uuid,p_user uuid,p_start date) returns void
language plpgsql set search_path='' as $$
declare a app.ph_payroll_attestation; d app.ph_payroll_attestation_decision; s app.ph_monetary_snapshot; j app.ph_payroll_journal; inverse jsonb;
begin
 perform app.accounting_tenant_lock(p_org);
 if auth.uid() is null or auth.uid()=p_user or not app.has_permission(p_org,'payroll.prepare') or not app.has_permission(p_org,'timesheet.lock') then raise exception 'forbidden' using errcode='42501';end if;
 if exists(select 1 from app.ph_statutory_journal where organization_id=p_org and user_id=p_user and category in ('separation','retirement')) then raise exception 'exit entitlement requires correction reconciliation' using errcode='P0001';end if;
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