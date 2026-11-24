
-- P1.4: immutable ancillary statutory journals, not a parallel payroll engine.
-- Only independently reviewed evidence; no external payment or agency submission.
alter table app.ph_payroll_attestation drop constraint ph_payroll_attestation_kind_check;
alter table app.ph_payroll_attestation add check(kind in ('opening','month','divisor','week','annual','salary_month','settlement_journal','custody_policy','statutory_quote','cutoff_opening','period','wage','contribution','reversal','entitlement','replay','cutoff_final','weekly_replay','form1601c','statutory_accrual','sss_reimbursement','maternity_reconciliation'));
create table app.ph_statutory_journal(
 organization_id uuid not null,user_id uuid not null,
 attestation_id uuid primary key references app.ph_payroll_attestation,
 quote_id uuid not null references app.ph_payroll_attestation,
 category text not null check(category in ('maternity_advance','sss_reimbursement','separation','retirement','maternity_contribution')),
 event_on date not null,covered_from date not null,covered_to date not null,
 source_digest text not null check(source_digest ~ '^[a-f0-9]{64}$'),
 result jsonb not null, lines jsonb not null check(jsonb_typeof(lines)='array'),
 debit_total numeric(18,2) not null,credit_total numeric(18,2) not null,
 recorded_by uuid not null references auth.users(id),recorded_at timestamptz not null default clock_timestamp(),
 foreign key(organization_id,user_id) references public.memberships(organization_id,user_id),
 unique(organization_id,source_digest),
 check(covered_from<=covered_to and debit_total=credit_total and debit_total>0)
);
create unique index ph_statutory_quote_once on app.ph_statutory_journal(quote_id) where category not in ('sss_reimbursement','maternity_contribution');
create unique index ph_maternity_contribution_once on app.ph_statutory_journal(quote_id) where category='maternity_contribution';
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
 values(p_org,auth.uid(),'accounting.ph_statutory_journal','attestation',a.id::text,jsonb_build_object('category',v_category));
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
 if y->>'reason' is distinct from 'termination' or (y->>'exitKind' is null or y->>'exitKind' not in ('ordinary_resignation_no_severance','separation','retirement') or (y->>'exitKind' in ('separation','retirement') and (y->>'statutoryAttestationId')::uuid is null)) or y->>'undispatched' is distinct from 'true' or y->>'completeExitEntitlements' is distinct from 'true' or y->>'rankAndFileEligible' is distinct from 'true' or not app.ph_stat_money((y->>'available')::numeric) then raise exception 'restricted reviewed final compensation required' using errcode='22023';end if;
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
 when 'maternity_reconciliation' then
 if (y->>'advanceAttestationId')::uuid is null or y->>'leaveApprovalVerified' is distinct from 'true'
 or y->>'noIntegratedAllowances' is distinct from 'true' or y->>'agencyBasesReviewed' is distinct from 'true'
 or length(btrim(coalesce(y->>'leaveEvidenceReference','')))<8 then raise exception 'reviewed maternity reconciliation evidence required' using errcode='22023';end if;
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

-- Private reconciliation of the existing effective payroll and ancillary
-- statutory journals. This is not a new ledger, payment or tax return.
create function app.ph_statutory_compensation_summary(p_org uuid,p_user uuid,p_year int) returns jsonb
language plpgsql set search_path='' as $$
declare g numeric;n numeric;t numeric;w numeric;mp numeric;diff numeric;advance numeric;received numeric;exit_j app.ph_statutory_journal;
begin
 perform app.accounting_tenant_lock(p_org);
 if auth.uid() is null or auth.uid()=p_user or not app.has_permission(p_org,'payroll.prepare') then raise exception 'forbidden' using errcode='42501';end if;
 if p_year is distinct from 2026 or app.ph_unresolved_reversal(p_org,p_user) then raise exception 'unsupported or unresolved compensation' using errcode='P0001';end if;
 if exists(select 1 from app.ph_statutory_journal j where j.organization_id=p_org and j.user_id=p_user and extract(year from j.event_on)=p_year
 and (j.debit_total is distinct from (select sum((x->>'debit')::numeric) from jsonb_array_elements(j.lines)x)
 or j.credit_total is distinct from (select sum((x->>'credit')::numeric) from jsonb_array_elements(j.lines)x)
 or j.debit_total<>j.credit_total)) then raise exception 'statutory journal mismatch' using errcode='P0001';end if;
 select coalesce(sum(gross),0),coalesce(sum(net),0),coalesce(sum(taxable),0),coalesce(sum(withholding),0) into g,n,t,w
 from app.ph_effective_monetary where organization_id=p_org and user_id=p_user and extract(year from pay_date)=p_year;
 select coalesce(sum((j.result->>'employeePaid')::numeric),0),coalesce(sum((j.result->>'salaryDifferential')::numeric),0),coalesce(sum((j.result->>'sssAdvance')::numeric),0)
 into mp,diff,advance from app.ph_statutory_journal j where j.organization_id=p_org and j.user_id=p_user and j.category='maternity_advance' and extract(year from j.event_on)=p_year;
 select coalesce(sum((j.result->>'amount')::numeric),0) into received from app.ph_statutory_journal j where j.organization_id=p_org and j.user_id=p_user and j.category='sss_reimbursement' and extract(year from j.event_on)=p_year;
 if mp<>diff+advance or received>advance then raise exception 'maternity amounts do not reconcile' using errcode='P0001';end if;
 select * into exit_j from app.ph_statutory_journal where organization_id=p_org and user_id=p_user and category in ('separation','retirement') and extract(year from event_on)=p_year;
 if found and not exists(select 1 from app.ph_effective_monetary m where m.organization_id=p_org and m.user_id=p_user
 and m.period_start=(exit_j.result->>'finalPeriod')::date and m.revision=(exit_j.result->>'finalRevision')::int
 and m.pay_date+1=exit_j.covered_from and not exists(select 1 from app.ph_effective_monetary z where z.organization_id=p_org and z.user_id=p_user and z.pay_date>m.pay_date))
 then raise exception 'exit journal revision mismatch' using errcode='P0001';end if;
 return jsonb_build_object('taxYear',p_year,'ordinaryGross',g,'ordinaryNetAccrued',n,'ordinaryTaxable',t,'ordinaryWithholding',w,
 'maternityEmployeeAlreadyPaid',mp,'maternitySalaryDifferential',diff,'sssAdvanced',advance,'sssReimbursedToEmployer',received,'sssReceivable',advance-received,
 'exitCategory',exit_j.category,'exitAttestationId',exit_j.attestation_id,'exitPayableAccrued',coalesce((exit_j.result->>'amount')::numeric,0),
 'exitPeriod',exit_j.result->>'finalPeriod','exitRevision',exit_j.result->>'finalRevision',
 'maternityCoverageIntegrated',mp=0,'paymentInitiated',false);
end $$;
revoke all on function app.ph_statutory_compensation_summary(uuid,uuid,int) from public,anon,authenticated,service_role;

create or replace function app.ph_record_cutoff_final(p_org uuid,p_user uuid,p_start date) returns jsonb
language plpgsql set search_path='' as $$
declare a app.ph_payroll_attestation; o app.ph_payroll_attestation; s app.ph_monetary_snapshot; h app.ph_employment_history;
 t numeric; w numeric; basic numeric; paid numeric; avail numeric; j jsonb; e date; sc jsonb; exit_amount numeric;
begin
 perform app.accounting_tenant_lock(p_org);
 if auth.uid() is null or auth.uid()=p_user or not app.has_permission(p_org,'payroll.prepare') or not app.has_permission(p_org,'timesheet.lock') then raise exception 'forbidden' using errcode='42501';end if;
 if app.ph_unresolved_reversal(p_org,p_user) then raise exception 'unresolved reversal' using errcode='P0001';end if;
 a:=app.ph_approved_evidence(p_org,p_user,'cutoff_final',p_start);
 if a.maker=auth.uid() then raise exception 'independent settlement required' using errcode='42501';end if;
 o:=app.ph_approved_evidence(p_org,p_user,'cutoff_opening','2026-01-01');
 select * into s from app.ph_effective_monetary where organization_id=p_org and user_id=p_user and period_start=p_start;
 if not found or s.frequency not in ('daily','semi-monthly','monthly') or exists(select 1 from app.ph_effective_monetary x where x.organization_id=p_org and x.user_id=p_user and x.period_start>p_start) then raise exception 'latest effective cutoff required' using errcode='P0001';end if;

 e:=s.pay_date;
 sc:=app.ph_statutory_compensation_summary(p_org,p_user,2026);
 if (sc->>'maternityEmployeeAlreadyPaid')::numeric<>0 then raise exception 'maternity period coverage and agency reconciliation required' using errcode='P0001';end if;
 exit_amount:=(sc->>'exitPayableAccrued')::numeric;
 if a.payload->>'exitKind'='ordinary_resignation_no_severance' then
 if exit_amount<>0 then raise exception 'ordinary resignation conflicts with statutory exit journal' using errcode='P0001';end if;
 else
 if exit_amount<=0 or a.payload->>'exitKind' is distinct from sc->>'exitCategory' or a.payload->>'statutoryAttestationId' is distinct from sc->>'exitAttestationId'
 or sc->>'exitPeriod' is distinct from p_start::text or (sc->>'exitRevision')::int is distinct from s.revision then raise exception 'exact reviewed statutory exit required' using errcode='P0001';end if;
 end if;
 if not exists(select 1 from public.memberships where organization_id=p_org and user_id=p_user and status='ended')
 or exists(select 1 from app.ph_2316_import where organization_id=p_org and user_id=p_user and tax_year=2026)
 or o.payload->'certificates' is distinct from '[]'::jsonb
 or (o.payload->>'previousPeriods')::int<>0 then raise exception 'restricted final termination scope' using errcode='P0001';end if;
 h:=app.ph_employment_as_of(p_org,p_user,e+1,clock_timestamp());
 if h.status is distinct from 'separated' or h.effective_on is distinct from e+1 then raise exception 'reviewed separation required' using errcode='P0001';end if;
 if e+1<((o.payload->>'firstPeriod')::date+interval '1 month')::date
 or exists(select 1 from generate_series((o.payload->>'firstPeriod')::date,e,interval '1 day') g where not exists(select 1 from app.ph_effective_monetary m where m.organization_id=p_org and m.user_id=p_user and g::date between m.period_start and m.pay_date)) then raise exception 'complete final year coverage required' using errcode='P0001';end if;
 if exists(select 1 from app.ph_benefit_event x where x.organization_id=p_org and x.user_id=p_user and x.tax_year=2026 and not exists(select 1 from app.ph_effective_monetary m where m.organization_id=p_org and m.user_id=p_user and x.paid_on between m.period_start and m.pay_date and m.evidence->'benefitKeys' ? x.event_key)) then raise exception 'unreconciled benefits' using errcode='P0001';end if;
 -- All monthly liabilities must be allocated, including the final month;
 -- otherwise final settlement would silently omit statutory deductions.
 if exists(select 1 from generate_series(date_trunc('month',(o.payload->>'firstPeriod')::date)::date,date_trunc('month',e)::date,interval '1 month') g
 where not exists(select 1 from app.ph_payroll_attestation c join app.ph_payroll_attestation_decision d on d.attestation_id=c.id
 join app.ph_effective_monetary m on m.organization_id=c.organization_id and m.user_id=c.user_id and m.pay_date=(c.payload->>'allocationDate')::date and m.evidence->>'contributionEvidence'=c.id::text
 where c.organization_id=p_org and c.user_id=p_user and c.kind='contribution' and c.scope_date=g::date and m.pay_date<=e))
 then raise exception 'unallocated final contributions' using errcode='P0001';end if;
 select coalesce(sum(m.taxable),0),coalesce(sum(m.withholding),0),coalesce(sum((m.evidence->>'basic')::numeric),0) into t,w,basic from app.ph_effective_monetary m where m.organization_id=p_org and m.user_id=p_user and extract(year from m.pay_date)=2026;
 select coalesce(sum((x.result->>'gross')::numeric),0) into paid from app.ph_benefit_event x where x.organization_id=p_org and x.user_id=p_user and x.tax_year=2026 and x.request->>'code'='13th_month';
 if paid<>round(basic/12,2) then raise exception 'thirteenth entitlement requires reconciliation' using errcode='P0001';end if;
 avail:=(a.payload->>'available')::numeric;
 if avail>s.net then raise exception 'available final compensation exceeds accrual' using errcode='22023';end if;

 j:=app.ph_annual_adjustment(e,e,'termination',t,0,w,0,avail,a.evidence);
 if exit_amount>0 then
 -- Existing exit payable was already journaled. Do not accrue it again.
 -- Annual adjustment journal still handles only the withholding difference.
 j:=j||jsonb_build_object('statutoryCompensation',sc,'finalCompensationCandidate',jsonb_build_object(
 'ordinaryFinalNetAccrual',s.net,'exemptExitPayableAccrual',exit_amount,'annualRefundAccrual',(j->>'refund')::numeric,
 'additionalEmployeeWithholding',(j->>'employeeWithholding')::numeric,
 'combinedAccrualCandidate',s.net+exit_amount+(j->>'refund')::numeric-(j->>'employeeWithholding')::numeric,'paymentInitiated',false));
 end if;
 insert into app.ph_annual_settlement(organization_id,user_id,tax_year,final_period,attestation_id,result,recorded_by,final_revision)
 values(p_org,p_user,2026,p_start,a.id,j,auth.uid(),s.revision);
 insert into public.audit_events(organization_id,actor_id,action,entity,entity_id,data)
 values(p_org,auth.uid(),'accounting.ph_cutoff_final','membership',p_user::text,jsonb_build_object('period',p_start,'revision',s.revision));
 return j;
end $$;

create or replace function app.ph_guard_statutory_final() returns trigger language plpgsql set search_path='' as $$
declare sc jsonb;a app.ph_payroll_attestation;
begin
 perform app.accounting_tenant_lock(new.organization_id);
 if not exists(select 1 from app.ph_statutory_journal where organization_id=new.organization_id and user_id=new.user_id and category<>'sss_reimbursement') then return new;end if;
 if exists(select 1 from app.ph_statutory_journal where organization_id=new.organization_id and user_id=new.user_id and category='maternity_advance') then raise exception 'statutory maternity coverage requires integrated reconciliation' using errcode='P0001';end if;
 sc:=app.ph_statutory_compensation_summary(new.organization_id,new.user_id,new.tax_year);
 a:=app.ph_approved_evidence(new.organization_id,new.user_id,'cutoff_final',new.final_period);
 if a.id<>new.attestation_id or new.result->'statutoryCompensation' is distinct from sc
 or a.payload->>'statutoryAttestationId' is distinct from sc->>'exitAttestationId'
 or a.payload->>'exitKind' is distinct from sc->>'exitCategory'
 or sc->>'exitPeriod' is distinct from new.final_period::text or (sc->>'exitRevision')::int is distinct from new.final_revision
 then raise exception 'exact statutory final reconciliation required' using errcode='P0001';end if;
 return new;
end $$;


-- Reconcile the reviewed maternity advance against immutable locked workday
-- evidence and existing monthly agency basis attestations. This is a private,
-- read-only reconciliation, not a payment, remittance, new payroll engine or
-- permission to skip a chronological ordinary payroll cutoff.
create function app.ph_reconcile_maternity_coverage(p_org uuid,p_user uuid,p_day date) returns jsonb
language plpgsql set search_path='' as $$
declare a app.ph_payroll_attestation;j app.ph_statutory_journal;h app.ph_employment_history;first_h app.ph_employment_history;
 ev app.ph_workday_evidence;z app.accounting_locked_snapshot;ca app.ph_payroll_attestation;
 d date;wk date;mon date;agency text;c jsonb;monthly jsonb;shares jsonb;part jsonb;mat_ee numeric;mat_er numeric;ordinary_basic numeric;covered int;months jsonb:='[]';
 ee numeric:=0;er numeric:=0;full_pay numeric;days int;basis numeric;paid numeric;diff numeric;basic numeric;thirteenth jsonb;
begin
 perform app.accounting_tenant_lock(p_org);
 if auth.uid() is null or auth.uid()=p_user or not app.has_permission(p_org,'payroll.prepare') or not app.has_permission(p_org,'timesheet.lock') then raise exception 'forbidden' using errcode='42501';end if;
 a:=app.ph_approved_evidence(p_org,p_user,'maternity_reconciliation',p_day);
 if a.maker=auth.uid() then raise exception 'independent maternity reconciliation required' using errcode='42501';end if;
 select * into j from app.ph_statutory_journal where organization_id=p_org and user_id=p_user and attestation_id=(a.payload->>'advanceAttestationId')::uuid and category='maternity_advance';
 if not found or p_day<>j.covered_to or app.ph_unresolved_reversal(p_org,p_user)
 or exists(select 1 from app.ph_annual_settlement where organization_id=p_org and user_id=p_user and tax_year=2026)
 then raise exception 'exact open maternity advance required' using errcode='P0001';end if;
 days:=j.covered_to-j.covered_from+1;
 first_h:=app.ph_employment_as_of(p_org,p_user,j.covered_from,clock_timestamp());
 if first_h.status is distinct from 'employed' or first_h.pay_basis is distinct from 'monthly' then raise exception 'stable monthly salary candidate required' using errcode='P0001';end if;
 full_pay:=round(first_h.rate_php*days/30,2);
 if full_pay is distinct from (j.result->>'fullPay')::numeric then raise exception 'reviewed full pay differs from historical salary' using errcode='P0001';end if;
 if exists(select 1 from app.ph_effective_monetary m where m.organization_id=p_org and m.user_id=p_user and m.period_start<=j.covered_to and m.pay_date>=j.covered_from)
 then raise exception 'ordinary payroll overlaps maternity' using errcode='P0001';end if;
 if exists(select 1 from app.accounting_adjustment_proposal x where x.organization_id=p_org and x.user_id=p_user and x.period_start<=j.covered_to and x.period_start+6>=j.covered_from) then raise exception 'attendance adjustment requires review' using errcode='P0001';end if;
 -- Every maternity day must have the exact historical employment revision
 -- and locked v4 attendance, with no work line in either day attribution.
 for d in select g::date from generate_series(j.covered_from,j.covered_to,interval '1 day') g loop
 wk:=d-(extract(isodow from d)::int-1);
 h:=app.ph_employment_as_of(p_org,p_user,d,clock_timestamp());
 select * into ev from app.ph_workday_evidence where organization_id=p_org and user_id=p_user and work_date=d and period_start=wk;
 if not found or h.status is distinct from 'employed' or (h.effective_on,h.recorded_at) is distinct from (first_h.effective_on,first_h.recorded_at)
 or (ev.employment_effective_on,ev.employment_recorded_at) is distinct from (h.effective_on,h.recorded_at)
 then raise exception 'missing or changed maternity workday evidence' using errcode='P0001';end if;
 select * into z from app.accounting_locked_snapshot where organization_id=p_org and user_id=p_user and period_start=wk;
 if not found or z.reconciliation->>'classificationVersion' is distinct from '4' or coalesce((z.reconciliation->>'exactOvertimeReviewSeconds')::numeric,1)<>0
 or jsonb_typeof(z.reconciliation->'payLines') is distinct from 'array'
 or not exists(select 1 from public.payroll_periods where organization_id=p_org and period_start=wk)
 or exists(select 1 from jsonb_array_elements(z.reconciliation->'payLines') x where (x->>'date')::date=d or (x->>'workday')::date=d)
 then raise exception 'locked maternity day must contain no ordinary work' using errcode='P0001';end if;
 end loop;
 -- Reuse the existing agency candidate and monthly contribution attestation.
 -- Reject any ordinary payroll or other maternity advance in those months:
 -- shared-month allocation requires a more general contribution engine.
 for mon in select g::date from generate_series(date_trunc('month',j.covered_from)::date,date_trunc('month',j.covered_to)::date,interval '1 month') g loop
 if exists(select 1 from app.ph_effective_monetary m where m.organization_id=p_org and m.user_id=p_user and m.pay_date>=mon and m.pay_date<(mon+interval '1 month')::date)
 or exists(select 1 from app.ph_statutory_journal x where x.organization_id=p_org and x.user_id=p_user and x.category='maternity_advance' and x.attestation_id<>j.attestation_id and x.covered_from<(mon+interval '1 month')::date and x.covered_to>=mon)
 then raise exception 'shared month requires contribution allocation review' using errcode='P0001';end if;
 ca:=app.ph_approved_evidence(p_org,p_user,'contribution',mon);

 monthly:='{}'::jsonb;shares:='{}'::jsonb;
 covered:=least(j.covered_to,(mon+interval '1 month - 1 day')::date)-greatest(j.covered_from,mon)+1;
 ordinary_basic:=round(first_h.rate_php*((mon+interval '1 month')::date-mon-covered)/((mon+interval '1 month')::date-mon),2);
 if a.payload ? 'allocations' and (jsonb_typeof(a.payload->'allocations'->mon::text) is distinct from 'object' or
 (a.payload->'allocations'->mon::text->>'ordinaryBasic')::numeric is distinct from ordinary_basic) then raise exception 'reviewed partial salary allocation differs from calendar method' using errcode='P0001';end if;
 foreach agency in array array['sss','philhealth','pagibig'] loop
 basis:=(ca.payload->>agency)::numeric;
 c:=app.ph_contribution_candidate(agency,basis,mon);

 if a.payload ? 'allocations' then
 part:=a.payload->'allocations'->mon::text->'agencies'->agency;
 if jsonb_typeof(part) is distinct from 'object' then raise exception 'reviewed monthly split required' using errcode='P0001';end if;
 mat_ee:=(part->>'employee')::numeric;mat_er:=(part->>'employer')::numeric;
 else mat_ee:=(c->>'employee')::numeric;mat_er:=(c->>'employer')::numeric;end if;
 if not app.ph_stat_money(mat_ee) or not app.ph_stat_money(mat_er) or mat_ee>(c->>'employee')::numeric or mat_er>(c->>'employer')::numeric
 or (ordinary_basic=0 and (mat_ee,mat_er) is distinct from ((c->>'employee')::numeric,(c->>'employer')::numeric))
 then raise exception 'invalid or incomplete monthly contribution split' using errcode='P0001';end if;
 shares:=shares||jsonb_build_object(agency,jsonb_build_object('employee',mat_ee,'employer',mat_er,'total',mat_ee+mat_er,
 'ordinaryEmployee',(c->>'employee')::numeric-mat_ee,'ordinaryEmployer',(c->>'employer')::numeric-mat_er));
 ee:=ee+mat_ee;er:=er+mat_er;
 monthly:=monthly||jsonb_build_object(agency,c);
 end loop;
 months:=months||jsonb_build_array(jsonb_build_object('month',mon,'contributionAttestation',ca.id,'agencies',monthly,'maternityShares',shares,'ordinaryBasic',ordinary_basic,'coveredDays',covered));
 end loop;
 diff:=(j.result->>'salaryDifferential')::numeric;
 if ee is distinct from (j.result->>'employeeContributions')::numeric
 or diff is distinct from greatest(0,full_pay-ee-(j.result->>'sssAdvance')::numeric)
 then raise exception 'maternity deductions differ from reviewed agency totals' using errcode='P0001';end if;
 -- Existing eligible basic is derived from canonical cutoff evidence. The
 -- restricted candidate does not claim a complete year or a 13th-month payment.
 if exists(select 1 from app.ph_effective_monetary m where m.organization_id=p_org and m.user_id=p_user and extract(year from m.pay_date)=2026 and (m.frequency='weekly' or m.evidence->>'basic' is null))
 or exists(select 1 from app.ph_statutory_journal x where x.organization_id=p_org and x.user_id=p_user and x.category='maternity_advance' and x.attestation_id<>j.attestation_id)
 then raise exception 'broader basic salary reconciliation required' using errcode='P0001';end if;
 select coalesce(sum((m.evidence->>'basic')::numeric),0) into basic from app.ph_effective_monetary m where m.organization_id=p_org and m.user_id=p_user and extract(year from m.pay_date)=2026;
 select coalesce(sum((x.result->>'gross')::numeric),0) into paid from app.ph_benefit_event x where x.organization_id=p_org and x.user_id=p_user and x.tax_year=2026 and x.request->>'code'='13th_month';
 thirteenth:=app.ph_thirteenth_amount(basic,diff,0,paid,true,a.evidence);
 return jsonb_build_object('coveredFrom',j.covered_from,'coveredTo',j.covered_to,'coveredDays',days,
 'lockedCoverageVerified',true,'fullPay',full_pay,'employeeContributions',ee,'employerContributions',er,'contributionMonths',months,
 'salaryDifferential',diff,'sssAdvance',(j.result->>'sssAdvance')::numeric,'ordinaryBasic',basic,'thirteenthCandidate',thirteenth,
 'contributionJournalPosted',false,'finalCloseEnabled',false,'paymentInitiated',false);
end $$;
revoke all on function app.ph_reconcile_maternity_coverage(uuid,uuid,date) from public,anon,authenticated,service_role;


-- One immutable contribution journal per original advance, with reviewed
-- agency/month allocation details. The original advance journal already
-- recorded the net differential: gross it up for the withheld employee share.
create function app.ph_post_maternity_contributions(p_org uuid,p_user uuid,p_day date) returns jsonb
language plpgsql set search_path='' as $$
declare a app.ph_payroll_attestation;adv app.ph_statutory_journal;old app.ph_statutory_journal;v jsonb;lines jsonb;agency text;amount numeric;ee numeric;er numeric;digest text;
begin
 perform app.accounting_tenant_lock(p_org);
 if auth.uid() is null or auth.uid()=p_user or not app.has_permission(p_org,'payroll.prepare') or not app.has_permission(p_org,'timesheet.lock') then raise exception 'forbidden' using errcode='42501';end if;
 a:=app.ph_approved_evidence(p_org,p_user,'maternity_reconciliation',p_day);
 if a.maker=auth.uid() then raise exception 'independent maternity posting required' using errcode='42501';end if;
 select * into old from app.ph_statutory_journal where attestation_id=a.id;
 if found then return old.result;end if;
 if jsonb_typeof(a.payload->'allocations') is distinct from 'object' or a.payload->>'allocationMethod' is distinct from 'reviewed-calendar-residual-v1'
 or coalesce(a.payload->>'sourceDigest','') !~ '^[a-f0-9]{64}$' then raise exception 'explicit reviewed allocation required' using errcode='P0001';end if;
 v:=app.ph_reconcile_maternity_coverage(p_org,p_user,p_day);
 select * into strict adv from app.ph_statutory_journal where attestation_id=(a.payload->>'advanceAttestationId')::uuid and organization_id=p_org and user_id=p_user and category='maternity_advance';
 if exists(select 1 from app.ph_month_report where organization_id=p_org and month_start between date_trunc('month',adv.covered_from)::date and date_trunc('month',adv.covered_to)::date) then raise exception 'closed month requires amendment' using errcode='P0001';end if;
 ee:=(v->>'employeeContributions')::numeric;er:=(v->>'employerContributions')::numeric;
 if ee+er<=0 then raise exception 'positive contribution allocation required' using errcode='P0001';end if;
 lines:=jsonb_build_array(jsonb_build_object('account','maternity_differential_expense','debit',ee,'credit',0),jsonb_build_object('account','employer_contribution_expense','debit',er,'credit',0));
 foreach agency in array array['sss','philhealth','pagibig'] loop
 select sum((m->'maternityShares'->agency->>'total')::numeric) into amount from jsonb_array_elements(v->'contributionMonths')m;
 lines:=lines||jsonb_build_array(jsonb_build_object('account',agency||'_payable','debit',0,'credit',amount));
 end loop;
 if (select sum((x->>'debit')::numeric-(x->>'credit')::numeric) from jsonb_array_elements(lines)x)<>0 then raise exception 'unbalanced maternity contribution journal' using errcode='P0001';end if;
 v:=v||jsonb_build_object('contributionJournalPosted',true,'advanceAttestationId',adv.attestation_id,'journalTotal',ee+er,'allocationAttestationId',a.id);
 insert into app.ph_statutory_journal(organization_id,user_id,attestation_id,quote_id,category,event_on,covered_from,covered_to,source_digest,result,lines,debit_total,credit_total,recorded_by)
 values(p_org,p_user,a.id,adv.quote_id,'maternity_contribution',p_day,adv.covered_from,adv.covered_to,a.payload->>'sourceDigest',v,lines,ee+er,ee+er,auth.uid());
 insert into public.audit_events(organization_id,actor_id,action,entity,entity_id,data) values(p_org,auth.uid(),'accounting.ph_maternity_contributions','attestation',a.id::text,jsonb_build_object('monthCount',jsonb_array_length(v->'contributionMonths')));
 return v;
end $$;

-- Only the same reviewed monthly residual path may occupy a maternity month.
create or replace function app.ph_guard_statutory_overlap() returns trigger language plpgsql set search_path='' as $$
begin
 perform app.accounting_tenant_lock(new.organization_id);
 if exists(select 1 from app.ph_statutory_journal j where j.organization_id=new.organization_id and j.user_id=new.user_id and
 ((j.category='maternity_advance' and j.covered_from<=new.pay_date and j.covered_to>=new.period_start
 and not (new.frequency='monthly' and new.revision=1 and exists(select 1 from app.ph_statutory_journal m where m.organization_id=j.organization_id and m.user_id=j.user_id and m.quote_id=j.quote_id and m.category='maternity_contribution' and new.evidence->>'maternityAllocation'=m.attestation_id::text)))
 or (j.category in ('separation','retirement') and new.pay_date>=j.covered_from))) then raise exception 'statutory compensation requires integrated reconciliation' using errcode='P0001';end if;
 return new;
end $$;
revoke all on function app.ph_post_maternity_contributions(uuid,uuid,date) from public,anon,authenticated,service_role;

create function app.ph_ordinary_contribution_residual(p_total jsonb,p_share jsonb) returns jsonb language plpgsql immutable set search_path='' as $$
declare ee numeric;er numeric;
begin
 ee:=(p_total->>'employee')::numeric-(p_share->>'employee')::numeric;er:=(p_total->>'employer')::numeric-(p_share->>'employer')::numeric;
 if not app.ph_stat_money(ee) or not app.ph_stat_money(er) or ee is distinct from (p_share->>'ordinaryEmployee')::numeric or er is distinct from (p_share->>'ordinaryEmployer')::numeric then raise exception 'agency residual mismatch' using errcode='P0001';end if;
 -- Do not mislabel full SSS components as residual components.
 return jsonb_build_object('employee',ee,'employer',er,'total',ee+er,'allocation','reviewed-maternity-residual-v1');
end $$;
revoke all on function app.ph_ordinary_contribution_residual(jsonb,jsonb) from public,anon,authenticated,service_role;

create or replace function app.ph_post_cutoff_version(p_org uuid,p_user uuid,p_start date,p_replay boolean)
returns jsonb language plpgsql set search_path='' as $$
declare a app.ph_payroll_attestation;o app.ph_payroll_attestation;wa app.ph_payroll_attestation;ca app.ph_payroll_attestation;
 h app.ph_employment_history; dv app.ph_salary_divisor_evidence; reviewed app.ph_employment_history; first_h app.ph_employment_history;ev app.ph_workday_evidence;z app.accounting_locked_snapshot;
 old app.ph_monetary_snapshot;y app.ph_benefit_year;b app.ph_benefit_event;original app.ph_monetary_snapshot; version_no int;
 freq text;e date;d date;wk date;mon date;alloc date;line jsonb;code text;nonwork jsonb;actual_ids jsonb;
 worked numeric;secs numeric;rate numeric;factor numeric;amount numeric;wage numeric;is_mwe boolean;any_mwe boolean:=false;any_non_mwe boolean:=false;
 basic numeric:=0;premium numeric:=0;qualifying numeric:=0;raw_basic numeric:=0;raw_premium numeric:=0;raw_exempt numeric:=0;
 extra numeric;hazard numeric;bg numeric:=0;be numeric:=0;gross numeric;exempt numeric;taxable numeric;ded numeric;ee numeric:=0;er numeric:=0;wt numeric;
 prior jsonb;pt numeric;pw numeric;n int;last_end date;sticky boolean;use_average boolean;avg_result jsonb;
 s jsonb;ph jsonb;f jsonb;contrib jsonb;calc jsonb;lines jsonb:='[]';bal numeric;regtax numeric;supptax numeric; maternity app.ph_statutory_journal; month_split jsonb; maternity_day boolean; ordinary_basic numeric;
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
 if not found or original.frequency not in ('daily','semi-monthly','monthly') or a.payload->>'originalAttestation' is distinct from original.evidence->>'attestation'
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

 select * into maternity from app.ph_statutory_journal where organization_id=p_org and user_id=p_user and category='maternity_contribution' and covered_from<=e and covered_to>=p_start;
 if found then
 if p_replay or freq<>'monthly' or a.payload->>'maternityAllocation' is distinct from maternity.attestation_id::text then raise exception 'reviewed monthly maternity allocation required' using errcode='P0001';end if;
 select x into month_split from jsonb_array_elements(maternity.result->'contributionMonths') x where (x->>'month')::date=p_start;
 if month_split is null then raise exception 'maternity month allocation missing' using errcode='P0001';end if;
 ordinary_basic:=(month_split->>'ordinaryBasic')::numeric;
 elsif exists(select 1 from app.ph_statutory_journal x where x.organization_id=p_org and x.user_id=p_user and x.category='maternity_advance' and x.covered_from<=e and x.covered_to>=p_start) then raise exception 'maternity contribution journal required' using errcode='P0001';
 elsif a.payload ? 'maternityAllocation' then raise exception 'unexpected maternity allocation' using errcode='P0001';end if;
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

 if exists(select 1 from public.approval_requests q where q.organization_id=p_org and q.requester_id=p_user and q.kind='leave' and q.status='approved' and (q.payload->>'start')::date<=e and (q.payload->>'end')::date>=p_start
 and not exists(select 1 from app.ph_paid_leave_allocation x where x.organization_id=p_org and x.user_id=p_user and x.request_id=q.id and x.work_date between p_start and e)) then raise exception 'cutoff leave requires approved allocation review' using errcode='P0001';end if;
 if exists(select 1 from app.ph_paid_leave_allocation x where x.organization_id=p_org and x.user_id=p_user and x.work_date between p_start and e and
 ((a.payload->'nonwork'->x.work_date::text->>'kind') is distinct from 'paid_leave' or (a.payload->'nonwork'->x.work_date::text->>'requestId') is distinct from x.request_id::text)) then raise exception 'unreconciled paid leave allocation' using errcode='P0001';end if;
 first_h:=app.ph_employment_as_of(p_org,p_user,p_start,clock_timestamp());
 if first_h.status<>'employed' then raise exception 'historically employed period required' using errcode='P0001';end if;
 if first_h.pay_basis not in ('daily','hourly','monthly') or freq not in ('daily','semi-monthly','monthly') or (first_h.pay_basis='monthly' and freq<>'monthly') then raise exception 'restricted cutoff compensation basis' using errcode='P0001';end if;
 for d in select p_start+i from generate_series(0,e-p_start)i loop
 wk:=d-(extract(isodow from d)::int-1);
 select * into ev from app.ph_workday_evidence where organization_id=p_org and user_id=p_user and work_date=d and period_start=wk;
 if not found then raise exception 'complete workday evidence required' using errcode='P0001';end if;
 h:=app.ph_employment_as_of(p_org,p_user,d,clock_timestamp());
 if h.status<>'employed' or (h.effective_on,h.recorded_at) is distinct from (ev.employment_effective_on,ev.employment_recorded_at)
 or h.pay_basis<>first_h.pay_basis or (h.pay_basis='monthly' and (h.effective_on,h.recorded_at) is distinct from (first_h.effective_on,first_h.recorded_at))
 then raise exception 'employment revision requires review' using errcode='P0001';end if;

 maternity_day:=month_split is not null and d between maternity.covered_from and maternity.covered_to;
 if maternity_day then
 if h.pay_basis<>'monthly' or a.payload->'nonwork'->d::text->>'kind' is distinct from 'maternity_covered'
 or exists(select 1 from app.ph_paid_leave_allocation x where x.organization_id=p_org and x.user_id=p_user and x.work_date=d)
 or not exists(select 1 from app.accounting_locked_snapshot q where q.organization_id=p_org and q.user_id=p_user and q.period_start=wk and q.reconciliation->>'classificationVersion'='4' and (q.reconciliation->>'exactOvertimeReviewSeconds')::numeric=0 and not exists(select 1 from jsonb_array_elements(q.reconciliation->'payLines') l where (l->>'workday')::date=d or (l->>'date')::date=d))
 then raise exception 'maternity day coverage conflicts with ordinary payroll' using errcode='P0001';end if;
 lines:=lines||jsonb_build_array(jsonb_build_object('date',d,'kind','maternity_covered','allocation',maternity.attestation_id));
 continue;
 end if;
 wa:=app.ph_wage_on(p_org,p_user,d,h.site_reference,h.wage_order_reference);
 wage:=(wa.payload->>'dailyMinimum')::numeric;

 if h.pay_basis='monthly' then
 reviewed:=app.ph_reviewed_month_salary(p_org,p_user,d,clock_timestamp());
 if (reviewed.effective_on,reviewed.recorded_at) is distinct from (h.effective_on,h.recorded_at) then raise exception 'reviewed monthly salary mismatch' using errcode='P0001';end if;
 perform app.ph_approved_evidence(p_org,p_user,'divisor',h.effective_on);
 select * into dv from app.ph_salary_divisor_evidence where (organization_id,user_id,effective_on,recorded_at)=(h.organization_id,h.user_id,h.effective_on,h.recorded_at);
 if not found then raise exception 'reviewed monthly salary divisor required' using errcode='P0001';end if;
 rate:=h.rate_php*12/dv.annual_paid_days/8;
 else rate:=case h.pay_basis when 'hourly' then h.rate_php when 'daily' then h.rate_php/8 else null end;end if;

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
 if h.pay_basis='monthly' and nonwork->>'kind' not in ('monthly_covered','paid_leave') then raise exception 'partial monthly salary requires separate review' using errcode='P0001';end if;
 if h.pay_basis<>'monthly' and nonwork->>'kind'='monthly_covered' then raise exception 'invalid monthly coverage' using errcode='P0001';end if;
 if nonwork->>'kind' in ('paid_leave','paid_regular_holiday') then
 
 if nonwork->>'kind'='paid_leave' then
 if is_mwe or coalesce(ev.calendar_classes->>d::text,'')<>'ordinary' then raise exception 'MWE or nonordinary leave classification needs review' using errcode='P0001';end if;
 amount:=rate*app.ph_cutoff_leave_minutes(p_org,p_user,p_start,e,d,nonwork)/60;
 if h.pay_basis='monthly' then amount:=0;end if;
 else amount:=rate*8;end if;
 raw_basic:=raw_basic+amount;if is_mwe then raw_exempt:=raw_exempt+amount;end if;
 end if;
 lines:=lines||jsonb_build_array(nonwork||jsonb_build_object('date',d,'wageEvidence',wa.id,'employmentRevision',h.recorded_at));
 end if;
 end loop;
 if any_mwe and any_non_mwe then raise exception 'MWE status changed within period' using errcode='P0001';end if;
 if exists(select 1 from jsonb_object_keys(a.payload->'nonwork') k where k::date not between p_start and e) then raise exception 'nonwork date outside cutoff' using errcode='22023';end if;
 if first_h.pay_basis='monthly' then
 if freq='monthly' then raw_basic:=coalesce(ordinary_basic,first_h.rate_php);
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

 if month_split is not null and (first_h.pay_basis<>'monthly' or any_mwe or (ordinary_basic=0 and (premium+extra+hazard+bg)<>0)
 or exists(select 1 from app.ph_benefit_event x where x.organization_id=p_org and x.user_id=p_user and x.paid_on between greatest(p_start,maternity.covered_from) and least(e,maternity.covered_to))) then raise exception 'unsupported maternity month compensation' using errcode='P0001';end if;
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

 if month_split is not null then
 if month_split->>'contributionAttestation' is distinct from ca.id::text then raise exception 'maternity agency evidence changed' using errcode='P0001';end if;
 s:=app.ph_ordinary_contribution_residual(s,month_split->'maternityShares'->'sss');
 ph:=app.ph_ordinary_contribution_residual(ph,month_split->'maternityShares'->'philhealth');
 f:=app.ph_ordinary_contribution_residual(f,month_split->'maternityShares'->'pagibig');
 end if;
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
 if month_split is not null and e<>alloc then raise exception 'monthly residual allocation date mismatch' using errcode='P0001';end if;
 calc:=jsonb_build_object('sourceVersion',2,'revision',version_no,'frequency',freq,'periodStart',p_start,'periodEnd',e,'payDate',e,'basic',basic,'premium',premium,
 'gross',gross,'exempt',exempt,'mweExempt',qualifying+case when any_mwe then hazard else 0 end,'employeeContrib',ee,'employerContrib',er,
 'taxDeductible',ded,'taxable',taxable,'withholding',wt,'net',gross-ee-wt,'employerCost',gross+er,'benefitKeys',actual_ids,
 'contributions',jsonb_build_object('sss',s,'philhealth',ph,'pagibig',f),'sss',s,'philhealth',ph,'pagibig',f,'contributionEvidence',ca.id,'priorEmployer',prior,'cumulative',use_average,'averageEvidence',avg_result,'lines',lines,'attestation',a.id);

 if month_split is not null then calc:=calc||jsonb_build_object('maternityAllocation',maternity.attestation_id,'maternityCoveredDays',month_split->'coveredDays','fullAgencyBasis',month_split->'agencies');end if;
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
create or replace function app.ph_settle_reviewed_thirteenth(p_org uuid,p_user uuid,p_day date) returns jsonb
language plpgsql set search_path='' as $$
declare a app.ph_payroll_attestation; q app.ph_payroll_attestation; j jsonb; basic numeric; paid numeric; amount numeric; o app.ph_payroll_attestation; last_day date; maternity_basic numeric:=0;
begin
 perform app.accounting_tenant_lock(p_org);
 if auth.uid() is null or auth.uid()=p_user or not app.has_permission(p_org,'payroll.prepare') or not app.has_permission(p_org,'timesheet.lock') then raise exception 'forbidden' using errcode='42501';end if;

 if exists(select 1 from app.ph_statutory_journal j where j.organization_id=p_org and j.user_id=p_user and j.category='maternity_advance' and
 (j.covered_to>=p_day or not exists(select 1 from app.ph_statutory_journal m where m.organization_id=p_org and m.user_id=p_user and m.quote_id=j.quote_id and m.category='maternity_contribution'
 and not exists(select 1 from jsonb_array_elements(m.result->'contributionMonths') x where not exists(select 1 from app.ph_effective_monetary s where s.organization_id=p_org and s.user_id=p_user and s.period_start=(x->>'month')::date and s.evidence->>'maternityAllocation'=m.attestation_id::text)))))
 then raise exception 'maternity differential requires integrated 13th review' using errcode='P0001';end if;
 select coalesce(sum((j.result->>'salaryDifferential')::numeric),0) into maternity_basic from app.ph_statutory_journal j where j.organization_id=p_org and j.user_id=p_user and j.category='maternity_advance';
 a:=app.ph_approved_evidence(p_org,p_user,'entitlement',p_day);
 if a.maker=auth.uid() then raise exception 'independent entitlement posting required' using errcode='42501';end if;
 q:=app.ph_approved_evidence(p_org,p_user,'statutory_quote',(a.payload->>'quoteDate')::date);
 if q.payload->>'category' is distinct from 'thirteenth' or (q.payload->>'maternity')::numeric is distinct from maternity_basic or (q.payload->>'integratedBasic')::numeric is distinct from 0 then raise exception 'restricted entitlement scope' using errcode='P0001';end if;
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
 if s.evidence ? 'maternityAllocation' then raise exception 'maternity residual correction requires allocation replay' using errcode='P0001';end if;
 select * into strict j from app.ph_payroll_journal where organization_id=p_org and user_id=p_user and period_start=p_start and revision=1;
 select jsonb_agg(jsonb_build_object('account',x->>'account','debit',(x->>'credit')::numeric,'credit',(x->>'debit')::numeric) order by ord)
 into inverse from jsonb_array_elements(j.lines) with ordinality as v(x,ord);
 insert into app.ph_canonical_reversal(organization_id,period_start,user_id,proposed_by,approved_by,attestation_id,lines,debit_total,credit_total)
 values(p_org,p_start,p_user,a.maker,auth.uid(),a.id,inverse,j.credit_total,j.debit_total);
 insert into public.audit_events(organization_id,actor_id,action,entity,entity_id,data)
 values(p_org,auth.uid(),'accounting.ph_canonical_reversed','membership',p_user::text,jsonb_build_object('periodStart',p_start));
end $$;