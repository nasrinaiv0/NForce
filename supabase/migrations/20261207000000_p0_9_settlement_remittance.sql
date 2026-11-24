
-- P0.9 staging-only private accounting. No external disbursement or filing.
alter table app.ph_payroll_attestation drop constraint ph_payroll_attestation_kind_check;
alter table app.ph_payroll_attestation add check(kind in ('opening','month','divisor','week','annual','salary_month','settlement_journal','custody_policy'));
-- Canonical stable-month salary allocation: cumulative rounding telescopes
-- to exactly the reviewed monthly salary, including months with 28/29/30/31 days.
-- This is a proposed payment allocation convention, not a statutory divisor.
create function app.ph_salary_calendar_allocation(p_rate numeric,p_day date)
returns numeric language plpgsql immutable set search_path='' as $$
declare n int; d int;
begin
 if p_rate is null or p_rate<=0 or p_rate>1000000000 or p_rate<>round(p_rate,2)
 or p_day is null or not isfinite(p_day) then raise exception 'invalid salary allocation' using errcode='22023'; end if;
 n:=extract(day from (date_trunc('month',p_day::timestamp)+interval '1 month - 1 day'))::int;
 d:=extract(day from p_day)::int;
 return round(p_rate*d/n,2)-round(p_rate*(d-1)/n,2);
end $$;
-- A full-month attestation binds a fixed historical salary revision. Do not
-- infer unpaid absences, proration, eligibility or contractual pay cycles.
create function app.ph_reviewed_month_salary(p_org uuid,p_user uuid,p_day date,p_known timestamptz)
returns app.ph_employment_history language plpgsql stable set search_path='' as $$
declare a app.ph_payroll_attestation; h app.ph_employment_history; d date; x app.ph_employment_history; m date;
begin
 m:=date_trunc('month',p_day::timestamp)::date;
 a:=app.ph_approved_evidence(p_org,p_user,'salary_month',m);
 if a.payload->>'method' is distinct from 'full-calendar-month-no-unpaid-days'
 or (m+interval '1 month')::date>date '2026-11-24'
 then raise exception 'closed full-month salary review required' using errcode='P0001'; end if;
 h:=app.ph_employment_as_of(p_org,p_user,m,p_known);
 if h.pay_basis is distinct from 'monthly' or h.status<>'employed'
 or h.recorded_at is distinct from (a.payload->>'recordedAt')::timestamptz
 or h.effective_on is distinct from (a.payload->>'effectiveOn')::date then raise exception 'reviewed salary revision mismatch' using errcode='P0001'; end if;
 for d in select generate_series(m,(m+interval '1 month - 1 day')::date,interval '1 day')::date loop
 x:=app.ph_employment_as_of(p_org,p_user,d,p_known);
 if (x.effective_on,x.recorded_at) is distinct from (h.effective_on,h.recorded_at) then raise exception 'partial month or salary change requires separate review' using errcode='P0001'; end if;
 end loop;
 return h;
end $$;
-- Actual approved leave usage and explicit day allocations, not caller
-- invented leave balances. Restricted to one request entirely within week.
create table app.ph_paid_leave_allocation (
 organization_id uuid not null,user_id uuid not null,period_start date not null,work_date date not null,
 request_id uuid not null references public.approval_requests(id),minutes int not null check(minutes between 1 and 480),
 primary key(organization_id,user_id,work_date),foreign key(organization_id,period_start,user_id,work_date) references app.ph_workday_evidence
);
create function app.ph_record_paid_leave_day(p_org uuid,p_user uuid,p_period date,p_day date,p_minutes int,p_request uuid)
returns void language plpgsql set search_path='' as $$
declare q public.approval_requests; used numeric; requested numeric;
begin
 perform app.accounting_tenant_lock(p_org);
 if auth.uid() is null or auth.uid()=p_user or not app.has_permission(p_org,'payroll.prepare') then raise exception 'forbidden' using errcode='42501'; end if;
 select * into q from public.approval_requests where id=p_request and organization_id=p_org and requester_id=p_user and kind='leave' and status='approved';
 if not found or p_day not between p_period and p_period+6 or (q.payload->>'start')::date<p_period or (q.payload->>'end')::date>p_period+6
 or p_day not between (q.payload->>'start')::date and (q.payload->>'end')::date then raise exception 'approved in-week leave request required' using errcode='P0001'; end if;
 select -days*480 into requested from public.leave_transactions where organization_id=p_org and user_id=p_user and request_id=p_request and kind='usage';
 if not found or requested<=0 then raise exception 'approved leave ledger usage missing' using errcode='P0001'; end if;
 select coalesce(sum(minutes),0) into used from app.ph_paid_leave_allocation where organization_id=p_org and user_id=p_user and request_id=p_request;
 if p_minutes is null or p_minutes<1 or p_minutes>480 or used+p_minutes>requested then raise exception 'leave allocation exceeds approved usage' using errcode='22023'; end if;
 if exists(select 1 from app.ph_monetary_snapshot where organization_id=p_org and user_id=p_user and period_start=p_period) then raise exception 'posted payroll requires correction' using errcode='42501'; end if;
 insert into app.ph_paid_leave_allocation values(p_org,p_user,p_period,p_day,p_request,p_minutes);
end $$;
-- Journal for an independently reviewed annual adjustment. No bank payment
-- is implied. Refund recoverability and employee advance recovery require CPA
-- and legal evidence; no automated deductions or offset of agency liability.
create table app.ph_annual_journal (
 organization_id uuid not null,user_id uuid not null,tax_year int not null,
 attestation_id uuid not null references app.ph_payroll_attestation,lines jsonb not null,
 debit_total numeric(18,2) not null,credit_total numeric(18,2) not null,
 primary key(organization_id,user_id,tax_year),foreign key(organization_id,user_id,tax_year) references app.ph_annual_settlement,
 check(debit_total=credit_total and debit_total>=0)
);
create function app.ph_annual_journal_lines(p_result jsonb) returns jsonb
language plpgsql immutable set search_path='' as $$
declare refund numeric; collect numeric; advance numeric; due numeric;
begin
 refund:=(p_result->>'refund')::numeric;collect:=(p_result->>'employeeWithholding')::numeric;advance:=(p_result->>'employerAdvance')::numeric;due:=(p_result->>'adjustment')::numeric;
 if refund is null or collect is null or advance is null or due is null
 or refund<0 or collect<0 or advance<0 or refund<>round(refund,2) or collect<>round(collect,2) or advance<>round(advance,2)
 or due<>collect+advance-refund or (refund>0 and collect+advance>0) then raise exception 'invalid annual journal amounts' using errcode='22023'; end if;
 return jsonb_build_array(jsonb_build_object('account','tax_refund_recoverable','debit',refund,'credit',0),
 jsonb_build_object('account','employee_refund_payable','debit',0,'credit',refund),
 jsonb_build_object('account','net_payable','debit',collect,'credit',0),
 jsonb_build_object('account','employee_advance_receivable','debit',advance,'credit',0),
 jsonb_build_object('account','withholding_payable','debit',0,'credit',collect+advance));
end $$;
create function app.ph_post_annual_journal(p_org uuid,p_user uuid,p_year int) returns void
language plpgsql set search_path='' as $$
declare s app.ph_annual_settlement; a app.ph_payroll_attestation; j jsonb; dt numeric; ct numeric;
begin
 perform app.accounting_tenant_lock(p_org);
 if auth.uid() is null or auth.uid()=p_user or not app.has_permission(p_org,'payroll.prepare') or not app.has_permission(p_org,'timesheet.lock') then raise exception 'forbidden' using errcode='42501'; end if;
 select * into s from app.ph_annual_settlement where organization_id=p_org and user_id=p_user and tax_year=p_year;
 if not found then raise exception 'annual settlement unavailable' using errcode='P0001'; end if;
 a:=app.ph_approved_evidence(p_org,p_user,'settlement_journal',s.final_period);
 if a.payload->>'treatment' is distinct from 'reviewed-recoverable-and-payable-accrual' or a.payload->'result' is distinct from s.result then raise exception 'exact reviewed settlement treatment required' using errcode='P0001'; end if;
 j:=app.ph_annual_journal_lines(s.result);
 select sum((x->>'debit')::numeric),sum((x->>'credit')::numeric) into dt,ct from jsonb_array_elements(j)x;
 insert into app.ph_annual_journal values(p_org,p_user,p_year,a.id,j,dt,ct);
 insert into public.audit_events(organization_id,actor_id,action,entity,entity_id,data)
 values(p_org,auth.uid(),'accounting.ph_annual_journal','membership',p_user::text,jsonb_build_object('year',p_year));
end $$;
-- Closed month, candidate internal reconciliation only. No TINs, statutory
-- form formatting, filing, payment initiation, deadlines or submission claims.
create table app.ph_month_report (
 organization_id uuid not null references public.organizations(id),month_start date not null,
 totals jsonb not null,source_periods jsonb not null,prepared_by uuid not null references auth.users(id),
 evidence text not null check(length(btrim(evidence)) between 8 and 300),prepared_at timestamptz not null default now(),
 primary key(organization_id,month_start)
);
create table app.ph_month_report_review (
 organization_id uuid not null,month_start date not null,checked_by uuid not null references auth.users(id),
 evidence text not null check(length(btrim(evidence)) between 8 and 300),
 primary key(organization_id,month_start),foreign key(organization_id,month_start) references app.ph_month_report
);
create table app.ph_remittance_receipt (
 organization_id uuid not null,month_start date not null,agency text not null check(agency in ('sss','philhealth','pagibig','bir')),
 receipt_reference text not null check(length(btrim(receipt_reference)) between 8 and 200),paid_on date not null,
 amount numeric(18,2) not null check(amount>0),recorded_by uuid not null references auth.users(id),
 evidence text not null check(length(btrim(evidence)) between 8 and 300),
 primary key(organization_id,agency,receipt_reference),foreign key(organization_id,month_start) references app.ph_month_report
);
create table app.ph_remittance_journal (
 organization_id uuid not null,agency text not null,receipt_reference text not null,
 checked_by uuid not null references auth.users(id),lines jsonb not null,
 debit_total numeric(18,2) not null,credit_total numeric(18,2) not null,
 primary key(organization_id,agency,receipt_reference),foreign key(organization_id,agency,receipt_reference) references app.ph_remittance_receipt,
 check(debit_total=credit_total and debit_total>0)
);
create function app.ph_month_report_totals(p_org uuid,p_month date) returns jsonb
language plpgsql stable set search_path='' as $$
declare j jsonb; e date; sss numeric; ph numeric; pi numeric; tax numeric; annual_due numeric;
begin
 if p_month is null or extract(day from p_month)<>1 or extract(year from p_month)<>2026 or (p_month+interval '1 month')::date>date '2026-11-24' then raise exception 'closed supported month required' using errcode='22023'; end if;
 e:=(p_month+interval '1 month')::date;
 if not exists(select 1 from app.ph_monetary_snapshot s where s.organization_id=p_org and s.pay_date>=p_month and s.pay_date<e)
 or exists(select 1 from app.accounting_locked_snapshot s where s.organization_id=p_org and s.period_start+6>=p_month and s.period_start+6<e and not exists(select 1 from app.ph_monetary_snapshot m where (m.organization_id,m.period_start,m.user_id)=(s.organization_id,s.period_start,s.user_id)))
 or exists(select 1 from app.ph_annual_settlement a where a.organization_id=p_org and a.final_period+6>=p_month and a.final_period+6<e and not exists(select 1 from app.ph_annual_journal j where (j.organization_id,j.user_id,j.tax_year)=(a.organization_id,a.user_id,a.tax_year)))
 then raise exception 'unposted locked payroll or settlement' using errcode='P0001'; end if;
 select coalesce(sum((s.evidence->'contributions'->'sss'->>'total')::numeric),0),coalesce(sum((s.evidence->'contributions'->'philhealth'->>'total')::numeric),0),coalesce(sum((s.evidence->'contributions'->'pagibig'->>'total')::numeric),0),sum(s.withholding)
 into sss,ph,pi,tax from app.ph_monetary_snapshot s where s.organization_id=p_org and s.pay_date>=p_month and s.pay_date<e;
 select coalesce(sum((a.result->>'employeeWithholding')::numeric+(a.result->>'employerAdvance')::numeric),0) into annual_due from app.ph_annual_settlement a join app.ph_annual_journal x using(organization_id,user_id,tax_year) where a.organization_id=p_org and a.final_period+6>=p_month and a.final_period+6<e;
 -- Refund receivables remain separate. No automatic offset against current BIR.
 return jsonb_build_object('sss',sss,'philhealth',ph,'pagibig',pi,'bir',tax+annual_due,'refundOffsetApplied',false);
end $$;
create function app.ph_prepare_month_report(p_org uuid,p_month date,p_evidence text) returns void
language plpgsql set search_path='' as $$
declare totals jsonb; src jsonb;
begin
 perform app.accounting_tenant_lock(p_org);
 if auth.uid() is null or not app.has_permission(p_org,'payroll.prepare') then raise exception 'forbidden' using errcode='42501'; end if;
 totals:=app.ph_month_report_totals(p_org,p_month);
 select jsonb_agg(jsonb_build_object('period',period_start,'employee',user_id) order by period_start,user_id) into src from app.ph_monetary_snapshot where organization_id=p_org and pay_date>=p_month and pay_date<(p_month+interval '1 month')::date;
 insert into app.ph_month_report(organization_id,month_start,totals,source_periods,prepared_by,evidence) values(p_org,p_month,totals,src,auth.uid(),p_evidence);
end $$;
create function app.ph_review_month_report(p_org uuid,p_month date,p_evidence text) returns void
language plpgsql set search_path='' as $$
declare r app.ph_month_report; src jsonb;
begin
 perform app.accounting_tenant_lock(p_org);
 if auth.uid() is null or not app.has_permission(p_org,'payroll.prepare') then raise exception 'forbidden' using errcode='42501'; end if;
 select * into r from app.ph_month_report where organization_id=p_org and month_start=p_month;
 if not found or r.prepared_by=auth.uid() then raise exception 'independent report review required' using errcode='42501'; end if;
 select jsonb_agg(jsonb_build_object('period',period_start,'employee',user_id) order by period_start,user_id) into src from app.ph_monetary_snapshot where organization_id=p_org and pay_date>=p_month and pay_date<(p_month+interval '1 month')::date;
 if r.totals is distinct from app.ph_month_report_totals(p_org,p_month) or r.source_periods is distinct from src then raise exception 'report source changed' using errcode='P0001'; end if;
 insert into app.ph_month_report_review values(p_org,p_month,auth.uid(),p_evidence);
end $$;
create function app.ph_record_remittance_receipt(p_org uuid,p_month date,p_agency text,p_reference text,p_paid date,p_amount numeric,p_evidence text) returns void
language plpgsql set search_path='' as $$
begin
 perform app.accounting_tenant_lock(p_org);
 if auth.uid() is null or not app.has_permission(p_org,'payroll.prepare') then raise exception 'forbidden' using errcode='42501'; end if;
 if p_amount is null or p_amount<=0 or p_amount>1000000000 or p_amount<>round(p_amount,2) or p_paid is null or p_paid<p_month or p_paid>date '2026-11-24' then raise exception 'invalid receipt' using errcode='22023'; end if;
 if not exists(select 1 from app.ph_month_report_review where organization_id=p_org and month_start=p_month) then raise exception 'reviewed report required' using errcode='P0001'; end if;
 insert into app.ph_remittance_receipt values(p_org,p_month,p_agency,p_reference,p_paid,p_amount,auth.uid(),p_evidence);
end $$;
create function app.ph_review_remittance_receipt(p_org uuid,p_agency text,p_reference text) returns void
language plpgsql set search_path='' as $$
declare r app.ph_remittance_receipt; report app.ph_month_report; paid numeric; due numeric;
begin
 perform app.accounting_tenant_lock(p_org);
 if auth.uid() is null or not app.has_permission(p_org,'payroll.prepare') then raise exception 'forbidden' using errcode='42501'; end if;
 select * into r from app.ph_remittance_receipt where organization_id=p_org and agency=p_agency and receipt_reference=p_reference;
 if not found or r.recorded_by=auth.uid() then raise exception 'independent receipt review required' using errcode='42501'; end if;
 select * into report from app.ph_month_report where organization_id=p_org and month_start=r.month_start;
 due:=(report.totals->>p_agency)::numeric;
 select coalesce(sum(x.amount),0) into paid from app.ph_remittance_receipt x join app.ph_remittance_journal j using(organization_id,agency,receipt_reference) where x.organization_id=p_org and x.month_start=r.month_start and x.agency=p_agency;
 if due is null or paid+r.amount>due then raise exception 'remittance exceeds reviewed liability' using errcode='P0001'; end if;
 insert into app.ph_remittance_journal values(p_org,p_agency,p_reference,auth.uid(),jsonb_build_array(jsonb_build_object('account',p_agency||'_payable','debit',r.amount,'credit',0),jsonb_build_object('account','bank','debit',0,'credit',r.amount)),r.amount,r.amount);
 insert into public.audit_events(organization_id,actor_id,action,entity,entity_id,data) values(p_org,auth.uid(),'accounting.ph_remittance_reviewed','remittance',p_reference,jsonb_build_object('agency',p_agency,'month',r.month_start));
end $$;
-- A reviewed report is a closed reconciliation boundary; later monetary
-- changes require a separate adjustment/report revision workflow.
create function app.ph_guard_reported_month() returns trigger language plpgsql set search_path='' as $$
declare p date;
begin
 perform app.accounting_tenant_lock(new.organization_id);
 p:=case when tg_table_name='ph_monetary_snapshot' then (to_jsonb(new)->>'pay_date')::date else (to_jsonb(new)->>'final_period')::date+6 end;
 if exists(select 1 from app.ph_month_report where organization_id=new.organization_id and month_start=date_trunc('month',p::timestamp)::date) then raise exception 'reported month requires revision workflow' using errcode='42501'; end if;
 return new;
end $$;
create trigger p09_reported_month before insert on app.ph_monetary_snapshot for each row execute function app.ph_guard_reported_month();
create trigger p09_reported_month before insert on app.ph_annual_settlement for each row execute function app.ph_guard_reported_month();
-- Immutable retention policy + key version evidence. Actual KMS and secure
-- erasure/backups are external acceptance gates, never implied by metadata.
create table app.ph_custody_policy (
 import_id uuid primary key references app.ph_2316_custody,
 organization_id uuid not null,user_id uuid not null,attestation_id uuid not null references app.ph_payroll_attestation,
 retain_until date not null,legal_hold boolean not null,policy_reference text not null,
 check(isfinite(retain_until) and length(btrim(policy_reference)) between 8 and 300)
);
create table app.ph_custody_key_version (
 import_id uuid not null references app.ph_custody_policy,version int not null check(version>0),
 key_reference text not null check(length(btrim(key_reference)) between 8 and 250),
 ciphertext bytea not null check(octet_length(ciphertext) between 32 and 10485760),
 sha256 text not null check(sha256=encode(pg_catalog.sha256(ciphertext),'hex')),
 recorded_by uuid not null references auth.users(id),recorded_at timestamptz not null default now(),
 primary key(import_id,version)
);
create table app.ph_custody_key_review (
 import_id uuid not null,version int not null,reviewed_by uuid not null references auth.users(id),
 evidence text not null check(length(btrim(evidence)) between 8 and 300),
 primary key(import_id,version),foreign key(import_id,version) references app.ph_custody_key_version
);
create function app.ph_register_custody_policy(p_org uuid,p_import uuid,p_scope date) returns void
language plpgsql set search_path='' as $$
declare c app.ph_2316_custody; a app.ph_payroll_attestation; until_date date;
begin
 perform app.accounting_tenant_lock(p_org);
 if auth.uid() is null or not app.has_permission(p_org,'payroll.prepare') then raise exception 'forbidden' using errcode='42501'; end if;
 select * into c from app.ph_2316_custody where organization_id=p_org and import_id=p_import;
 if not found or c.user_id=auth.uid() then raise exception 'forbidden' using errcode='42501'; end if;
 a:=app.ph_approved_evidence(p_org,c.user_id,'custody_policy',p_scope);
 until_date:=(a.payload->>'retainUntil')::date;
 if a.payload->>'importId' is distinct from p_import::text or until_date is null or not isfinite(until_date) or jsonb_typeof(a.payload->'legalHold') is distinct from 'boolean' then raise exception 'invalid reviewed retention evidence' using errcode='22023'; end if;
 insert into app.ph_custody_policy values(p_import,p_org,c.user_id,a.id,until_date,(a.payload->>'legalHold')::boolean,a.evidence);
end $$;
create function app.ph_stage_key_rotation(p_org uuid,p_import uuid,p_key text,p_cipher bytea) returns int
language plpgsql set search_path='' as $$
declare p app.ph_custody_policy; n int; oldkey text;
begin
 perform app.accounting_tenant_lock(p_org);
 if auth.uid() is null or not app.has_permission(p_org,'payroll.prepare') then raise exception 'forbidden' using errcode='42501'; end if;
 select * into p from app.ph_custody_policy where organization_id=p_org and import_id=p_import;
 if not found or p.user_id=auth.uid() or p.retain_until<current_date then raise exception 'rotation unavailable' using errcode='42501'; end if;
 select coalesce(max(version),0) into n from app.ph_custody_key_version where import_id=p_import;
 if n>0 and not exists(select 1 from app.ph_custody_key_review where import_id=p_import and version=n) then raise exception 'pending key rotation' using errcode='P0001'; end if;
 if n=0 then select key_reference into oldkey from app.ph_2316_custody where import_id=p_import; else select key_reference into oldkey from app.ph_custody_key_version where import_id=p_import and version=n; end if;
 if p_key is null or p_key=oldkey then raise exception 'new key reference required' using errcode='22023'; end if;
 insert into app.ph_custody_key_version(import_id,version,key_reference,ciphertext,sha256,recorded_by) values(p_import,n+1,p_key,p_cipher,encode(sha256(p_cipher),'hex'),auth.uid());
 return n+1;
end $$;
create function app.ph_review_key_rotation(p_org uuid,p_import uuid,p_version int,p_evidence text) returns void
language plpgsql set search_path='' as $$
declare v app.ph_custody_key_version; p app.ph_custody_policy;
begin
 perform app.accounting_tenant_lock(p_org);
 if auth.uid() is null or not app.has_permission(p_org,'payroll.prepare') then raise exception 'forbidden' using errcode='42501'; end if;
 select * into p from app.ph_custody_policy where organization_id=p_org and import_id=p_import;
 if not found or p.user_id=auth.uid() or p.retain_until<current_date then raise exception 'rotation unavailable' using errcode='42501'; end if;
 select * into v from app.ph_custody_key_version where import_id=p_import and version=p_version;
 if not found or v.recorded_by=auth.uid() then raise exception 'independent rotation review required' using errcode='42501'; end if;
 insert into app.ph_custody_key_review values(p_import,p_version,auth.uid(),p_evidence);
end $$;
create or replace function app.ph_get_reviewed_envelope(p_org uuid,p_import uuid) returns jsonb
language plpgsql set search_path='' as $$
declare c app.ph_2316_custody; p app.ph_custody_policy; v app.ph_custody_key_version; result jsonb;
begin
 perform app.accounting_tenant_lock(p_org);
 if auth.uid() is null or not app.has_permission(p_org,'payroll.prepare') then raise exception 'forbidden' using errcode='42501'; end if;
 select x.* into c from app.ph_2316_custody x join app.ph_2316_custody_review cr on cr.import_id=x.import_id join app.ph_2316_review r on r.import_id=x.import_id and r.approved where x.organization_id=p_org and x.import_id=p_import and x.user_id<>auth.uid();
 if not found then raise exception 'reviewed envelope unavailable' using errcode='42501'; end if;
 select * into p from app.ph_custody_policy where organization_id=p_org and import_id=p_import;
 if not found or p.retain_until<current_date then raise exception 'retention review or disposition required' using errcode='42501'; end if;
 select x.* into v from app.ph_custody_key_version x join app.ph_custody_key_review y using(import_id,version) where x.import_id=p_import order by x.version desc limit 1;
 if found then result:=jsonb_build_object('ciphertext',encode(v.ciphertext,'base64'),'sha256',v.sha256,'plaintextSha256',c.plaintext_sha256,'keyReference',v.key_reference,'version',v.version);
 else result:=jsonb_build_object('ciphertext',encode(c.ciphertext,'base64'),'sha256',c.ciphertext_sha256,'plaintextSha256',c.plaintext_sha256,'keyReference',c.key_reference,'version',0); end if;
 insert into public.audit_events(organization_id,actor_id,action,entity,entity_id,data) values(p_org,auth.uid(),'accounting.ph_envelope_retrieved','certificate',p_import::text,jsonb_build_object('version',result->'version'));
 return result;
end $$;
do $$ declare n text; begin
 foreach n in array array['ph_paid_leave_allocation','ph_annual_journal','ph_month_report','ph_month_report_review','ph_remittance_receipt','ph_remittance_journal','ph_custody_policy','ph_custody_key_version','ph_custody_key_review'] loop
 execute format('alter table app.%I enable row level security',n);
 execute format('revoke all on app.%I from public,anon,authenticated,service_role',n);
 execute format('create trigger p09_immutable before update or delete on app.%I for each row execute function app.forbid_mutation()',n);
 end loop;
end $$;
revoke all on function app.ph_salary_calendar_allocation(numeric,date),app.ph_reviewed_month_salary(uuid,uuid,date,timestamptz),app.ph_record_paid_leave_day(uuid,uuid,date,date,int,uuid),app.ph_annual_journal_lines(jsonb),app.ph_post_annual_journal(uuid,uuid,int),app.ph_month_report_totals(uuid,date),app.ph_prepare_month_report(uuid,date,text),app.ph_review_month_report(uuid,date,text),app.ph_record_remittance_receipt(uuid,date,text,text,date,numeric,text),app.ph_review_remittance_receipt(uuid,text,text),app.ph_guard_reported_month(),app.ph_register_custody_policy(uuid,uuid,date),app.ph_stage_key_rotation(uuid,uuid,text,bytea),app.ph_review_key_rotation(uuid,uuid,int,text) from public,anon,authenticated,service_role;

create or replace function app.ph_approve_payroll_evidence(p_org uuid,p_id uuid,p_evidence text)
returns void language plpgsql set search_path='' as $$
declare a app.ph_payroll_attestation; h app.ph_employment_history; y jsonb;
begin
 perform app.accounting_tenant_lock(p_org);
 if auth.uid() is null or not app.has_permission(p_org,'payroll.prepare') then raise exception 'forbidden' using errcode='42501'; end if;
 select * into a from app.ph_payroll_attestation where id=p_id and organization_id=p_org;
 if not found or auth.uid() in (a.maker,a.user_id) then raise exception 'independent checker required' using errcode='42501'; end if;
 y:=a.payload;
 case a.kind
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
 when 'annual' then
 if y->>'reason' is null or y->>'reason' not in ('year_end','termination') or (y->>'available')::numeric is null
 or (y->>'available')::numeric<0 or (y->>'available')::numeric<>round((y->>'available')::numeric,2)
 then raise exception 'invalid annual evidence' using errcode='22023'; end if;
 end case;
 insert into app.ph_payroll_attestation_decision values(a.id,auth.uid(),p_evidence,clock_timestamp());
 insert into public.audit_events(organization_id,actor_id,action,entity,entity_id,data)
 values(p_org,auth.uid(),'accounting.ph_evidence_approved','attestation',a.id::text,jsonb_build_object('kind',a.kind));
end $$;
create or replace function app.ph_post_monetary_week_2026(p_org uuid,p_period date,p_user uuid)
returns jsonb language plpgsql set search_path='' as $$
declare s app.accounting_locked_snapshot; o app.ph_monetary_opening; m app.ph_monthly_basis_evidence;
 h app.ph_employment_history; dv app.ph_salary_divisor_evidence; l jsonb;
 line_amount numeric; raw_gross numeric:=0; gross numeric; hourly numeric;
 ee numeric:=0; er numeric:=0; tax numeric; net numeric; taxable numeric;
 prev_taxable numeric; prev_tax numeric; n int; last_period date; pd date:=p_period+6; mon date;
 a app.ph_payroll_attestation; opening app.ph_payroll_attestation; prior jsonb; b app.ph_benefit_event; exempt numeric:=0; d date; minutes numeric; seen date[]:='{}'; ev_day app.ph_workday_evidence;
 salary_mode boolean:=false; salary_days int; known_at timestamptz; base_amount numeric; factor numeric; allocation app.ph_paid_leave_allocation; used numeric; req numeric;
 contrib jsonb:='{}'; j jsonb; agency text; basis numeric; v jsonb; lines jsonb:='[]'; journal jsonb; total numeric;
begin
 perform app.accounting_tenant_lock(p_org);
 if auth.uid() is null or auth.uid()=p_user or not app.has_permission(p_org,'payroll.prepare') or not app.has_permission(p_org,'timesheet.lock') then raise exception 'forbidden' using errcode='42501'; end if;
 if p_period is null or extract(isodow from p_period)<>1 or extract(year from pd)<>2026 or extract(year from p_period)<>2026 or pd>date '2026-11-24' then raise exception 'unsupported monetary period' using errcode='22023'; end if;
 if exists(select 1 from app.ph_monetary_snapshot where organization_id=p_org and period_start=p_period and user_id=p_user) then raise exception 'monetary snapshot already posted' using errcode='P0001'; end if;
 select * into s from app.accounting_locked_snapshot where organization_id=p_org and period_start=p_period and user_id=p_user;
 if not found or s.reconciliation->>'classificationVersion' is distinct from '4' or (s.reconciliation->>'exactOvertimeReviewSeconds')::numeric<>0 then raise exception 'locked exact reconciled PH attendance required' using errcode='P0001'; end if;
 if exists(select 1 from app.accounting_adjustment_proposal where organization_id=p_org and period_start=p_period and user_id=p_user) then raise exception 'adjusted payroll requires settlement review' using errcode='P0001'; end if;
 select * into o from app.ph_monetary_opening where organization_id=p_org and user_id=p_user and tax_year=2026;
 if not found then raise exception 'reviewed zero opening and coverage required' using errcode='P0001'; end if;
 opening:=app.ph_approved_evidence(p_org,p_user,'opening','2026-01-01');
 a:=app.ph_approved_evidence(p_org,p_user,'week',p_period);
 prior:=app.ph_prior_employer_2026(p_org,p_user);
 if exists(select 1 from app.ph_annual_settlement where organization_id=p_org and user_id=p_user and tax_year=2026) then raise exception 'annual settlement already recorded' using errcode='P0001'; end if;
 if not exists(select 1 from app.ph_benefit_year where organization_id=p_org and user_id=p_user and tax_year=2026 and opening_through<p_period)
 then raise exception 'reviewed benefit opening required' using errcode='P0001'; end if;
 select count(*)::int,coalesce(sum(x.taxable),0),coalesce(sum(x.withholding),0),max(x.period_start)
 into n,prev_taxable,prev_tax,last_period from app.ph_monetary_snapshot x where organization_id=p_org and user_id=p_user and extract(year from x.pay_date)=2026;
 if (n=0 and p_period<>o.first_period) or (n>0 and p_period<>last_period+7) then raise exception 'noncontiguous payroll history' using errcode='P0001'; end if;
 if exists(select 1 from app.ph_benefit_event b2 where b2.organization_id=p_org and b2.user_id=p_user and b2.tax_year=2026 and b2.paid_on<p_period and not exists(select 1 from app.ph_monetary_snapshot x where x.organization_id=p_org and x.user_id=p_user and b2.paid_on between x.period_start and x.pay_date)) then raise exception 'unreconciled earlier benefit' using errcode='P0001'; end if;
 select locked_at into known_at from public.payroll_periods where organization_id=p_org and period_start=p_period;
 select count(*) into salary_days from generate_series(p_period,pd,interval '1 day') g where exists(select 1 from app.ph_workday_evidence e2 join app.ph_employment_history eh on (eh.organization_id,eh.user_id,eh.effective_on,eh.recorded_at)=(e2.organization_id,e2.user_id,e2.employment_effective_on,e2.employment_recorded_at) where e2.organization_id=p_org and e2.user_id=p_user and e2.period_start=p_period and e2.work_date=g::date and eh.pay_basis='monthly');
 if salary_days>0 then
 if salary_days<>7 then raise exception 'monthly salary requires seven attested days' using errcode='P0001'; end if;
 salary_mode:=true;
 for d in select generate_series(p_period,pd,interval '1 day')::date loop
 h:=app.ph_reviewed_month_salary(p_org,p_user,d,known_at);
 if not exists(select 1 from app.ph_workday_evidence e2 where e2.organization_id=p_org and e2.user_id=p_user and e2.period_start=p_period and e2.work_date=d and e2.employment_effective_on=h.effective_on and e2.employment_recorded_at=h.recorded_at) then raise exception 'sealed salary revision mismatch' using errcode='P0001'; end if;
 base_amount:=app.ph_salary_calendar_allocation(h.rate_php,d);
 raw_gross:=raw_gross+base_amount;lines:=lines||jsonb_build_array(jsonb_build_object('date',d,'code','guaranteed_salary','amount',base_amount,'employmentRevision',h.recorded_at));
 end loop;
 end if;
 for l in select value from jsonb_array_elements(s.reconciliation->'payLines') loop
 select eh.* into h from app.ph_workday_evidence e join app.ph_employment_history eh on (eh.organization_id,eh.user_id,eh.effective_on,eh.recorded_at)=(e.organization_id,e.user_id,e.employment_effective_on,e.employment_recorded_at)
 where e.organization_id=p_org and e.period_start=p_period and e.user_id=p_user and e.work_date=(l->>'workday')::date;
 if not found or h.status<>'employed' then raise exception 'historical pay evidence missing' using errcode='P0001'; end if;
 if h.pay_basis='hourly' then hourly:=h.rate_php;
 elsif h.pay_basis='daily' then hourly:=h.rate_php/8;
 elsif h.pay_basis='monthly' then
 perform app.ph_approved_evidence(p_org,p_user,'divisor',h.effective_on);
 select * into dv from app.ph_salary_divisor_evidence where (organization_id,user_id,effective_on,recorded_at)=(h.organization_id,h.user_id,h.effective_on,h.recorded_at);
 if not found then raise exception 'reviewed salary divisor missing' using errcode='P0001'; end if;
 hourly:=h.rate_php*12/dv.annual_paid_days/8;
 else raise exception 'unsupported basis' using errcode='22023'; end if;
 factor:=(l->>'multiplier')::numeric;
 if h.pay_basis='monthly' then
 if not salary_mode then raise exception 'reviewed guaranteed salary coverage required' using errcode='P0001'; end if;
 if (l->>'code') not like '%_OT%' then factor:=factor-1; end if;
 end if;
 line_amount:=hourly*(l->>'seconds')::numeric/3600*factor;
 raw_gross:=raw_gross+line_amount;
 lines:=lines||jsonb_build_array(l||jsonb_build_object('hourlyRate',hourly,'unroundedAmount',line_amount,'employmentRevision',h.recorded_at));
 end loop;
 -- Paid nonwork: only independently attested zero-work dates in the sealed roster.
 for l in select value from jsonb_array_elements(a.payload->'nonwork') loop
 d:=(l->>'date')::date; minutes:=(l->>'minutes')::numeric;
 if d is null or d not between p_period and pd or d=any(seen) or minutes is null or minutes<=0 or minutes>480 or minutes<>trunc(minutes)
 or l->>'kind' is null or l->>'kind' not in ('paid_leave','paid_regular_holiday') or length(btrim(coalesce(l->>'reference','')))<8
 or exists(select 1 from jsonb_array_elements(s.reconciliation->'payLines') x where (x->>'date')::date=d or (x->>'workday')::date=d)
 then raise exception 'invalid or overlapping paid nonwork' using errcode='22023'; end if;
 select * into ev_day from app.ph_workday_evidence where organization_id=p_org and user_id=p_user and period_start=p_period and work_date=d;
 if not found or (l->>'kind'='paid_regular_holiday' and ev_day.calendar_classes->>d::text not in ('regular_holiday','regular_holiday_rest')) then raise exception 'nonwork calendar evidence missing' using errcode='P0001'; end if;
 select * into h from app.ph_employment_history where (organization_id,user_id,effective_on,recorded_at)=(ev_day.organization_id,ev_day.user_id,ev_day.employment_effective_on,ev_day.employment_recorded_at);
 if l->>'kind'='paid_leave' then
 select * into allocation from app.ph_paid_leave_allocation where organization_id=p_org and user_id=p_user and period_start=p_period and work_date=d;
 if not found or allocation.minutes<>minutes or allocation.request_id is distinct from (l->>'requestId')::uuid then raise exception 'approved paid leave allocation required' using errcode='P0001'; end if;
 select -days*480 into req from public.leave_transactions where request_id=allocation.request_id and organization_id=p_org and user_id=p_user and kind='usage';
 select sum(x.minutes) into used from app.ph_paid_leave_allocation x where x.organization_id=p_org and x.user_id=p_user and x.request_id=allocation.request_id;
 if req is null or used is distinct from req then raise exception 'incomplete approved leave allocation' using errcode='P0001'; end if;
 end if;
 if h.pay_basis='hourly' then hourly:=h.rate_php; line_amount:=hourly*minutes/60;
 elsif h.pay_basis='daily' then hourly:=h.rate_php/8; line_amount:=hourly*minutes/60;
 elsif h.pay_basis='monthly' and salary_mode then line_amount:=0;
 else raise exception 'paid nonwork salary basis requires separate review' using errcode='P0001'; end if; raw_gross:=raw_gross+line_amount; seen:=array_append(seen,d);
 lines:=lines||jsonb_build_array(l||jsonb_build_object('unroundedAmount',line_amount,'employmentRevision',h.recorded_at));
 end loop;
 if exists(select 1 from app.ph_paid_leave_allocation x where x.organization_id=p_org and x.user_id=p_user and x.period_start=p_period and not(x.work_date=any(seen))) then raise exception 'unreconciled paid leave day' using errcode='P0001'; end if;
 for l in select value from jsonb_array_elements(a.payload->'supplemental') loop
 line_amount:=(l->>'amount')::numeric;
 if l->>'code' is null or l->>'code' not in ('commission','taxable_allowance','other_taxable') or line_amount is null or line_amount<0 or line_amount>1000000000 or line_amount<>round(line_amount,2) or length(btrim(coalesce(l->>'reference','')))<8 then raise exception 'invalid supplemental evidence' using errcode='22023'; end if;
 raw_gross:=raw_gross+line_amount;lines:=lines||jsonb_build_array(l);
 end loop;
 gross:=round(raw_gross,2);
 for b in select * from app.ph_benefit_event where organization_id=p_org and user_id=p_user and tax_year=2026 and paid_on between p_period and pd order by sequence_no loop
 gross:=gross+(b.result->>'gross')::numeric;
 exempt:=exempt+(b.result->>'gross')::numeric-(b.result->>'taxable')::numeric;
 lines:=lines||jsonb_build_array(jsonb_build_object('benefitEvent',b.event_key,'result',b.result));
 end loop;
 mon:=date_trunc('month',pd::timestamp)::date;
 select * into m from app.ph_monthly_basis_evidence where organization_id=p_org and user_id=p_user and month_start=mon;
 if not found then raise exception 'reviewed monthly agency bases missing' using errcode='P0001'; end if;
 perform app.ph_approved_evidence(p_org,p_user,'month',mon);
 if p_period>m.allocation_period and not exists(select 1 from app.ph_monetary_snapshot where organization_id=p_org and user_id=p_user and period_start=m.allocation_period) then raise exception 'missing monthly allocation' using errcode='P0001'; end if;
 if p_period=m.allocation_period then
 foreach agency in array array['sss','philhealth','pagibig'] loop
 basis:=case agency when 'sss' then m.sss_basis when 'philhealth' then m.philhealth_basis else m.pagibig_basis end;
 v:=app.ph_contribution_candidate(agency,basis,mon);
 ee:=ee+(v->>'employee')::numeric;er:=er+(v->>'employer')::numeric;
 contrib:=contrib||jsonb_build_object(agency,v);
 end loop;
 end if;
 if gross-exempt<ee then raise exception 'insufficient compensation for contribution allocation' using errcode='P0001'; end if;
 taxable:=gross-exempt-ee;
 if prior->>'method'='cumulative' then
 j:=app.ph_cumulative_withholding(prev_taxable+taxable+(prior->>'taxable')::numeric,n+1+(prior->>'periods')::int,prev_tax+(prior->>'withheld')::numeric,'weekly',pd);
 else
 j:=jsonb_build_object('withhold',app.ph_tax_candidate(taxable,'weekly',pd),'method','weekly');
 end if;
 tax:=(j->>'withhold')::numeric;
 if tax>taxable then raise exception 'insufficient compensation for withholding' using errcode='P0001'; end if;
 net:=taxable+exempt-tax;
 total:=gross+er;
 journal:=jsonb_build_array(jsonb_build_object('account','wage_expense','debit',gross,'credit',0),
 jsonb_build_object('account','employer_contribution_expense','debit',er,'credit',0),
 jsonb_build_object('account','employee_contribution_payable','debit',0,'credit',ee),
 jsonb_build_object('account','employer_contribution_payable','debit',0,'credit',er),
 jsonb_build_object('account','withholding_payable','debit',0,'credit',tax),
 jsonb_build_object('account','net_payable','debit',0,'credit',net));
 if (select sum((x->>'debit')::numeric) from jsonb_array_elements(journal)x)<>total
 or (select sum((x->>'credit')::numeric) from jsonb_array_elements(journal)x)<>total then raise exception 'unbalanced payroll' using errcode='P0001'; end if;
 v:=jsonb_build_object('earnings',lines,'contributions',contrib,'cumulative',j,'openingEvidence',o.evidence,'basisEvidence',m.evidence,'method','ph-weekly-2026-reviewed-candidate','prior',prior,'attestation',a.id,'exempt',exempt);
 insert into app.ph_monetary_snapshot(organization_id,period_start,user_id,pay_date,gross,employee_contributions,employer_contributions,taxable,withholding,net,evidence,posted_by,exempt)
 values(p_org,p_period,p_user,pd,gross,ee,er,taxable,tax,net,v,auth.uid(),exempt);
 insert into app.ph_payroll_journal values(p_org,p_period,p_user,journal,total,total);
 insert into public.audit_events(organization_id,actor_id,action,entity,entity_id,data)
 values(p_org,auth.uid(),'accounting.ph_monetary_snapshot','membership',p_user::text,jsonb_build_object('periodStart',p_period));
 return jsonb_build_object('gross',gross,'exempt',exempt,'employeeContributions',ee,'employerContributions',er,'taxable',taxable,'withholding',tax,'net',net,'journalTotal',total);
end $$;
