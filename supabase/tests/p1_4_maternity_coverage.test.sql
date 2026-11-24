\set ON_ERROR_STOP on
begin;
\ir p0_3_fixture.sql
\ir p1_2_cutoff_fixture.sql
select pg_temp.seed9(27,'monthly','2026-02-01','monthly',30000,false,'none');
select set_config('request.jwt.claim.sub',pg_temp.u(4)::text,true);
select app.ph_post_cutoff_2026(pg_temp.org9(27),pg_temp.u(2),'2026-02-01');
-- March 2 through June 14 is exactly 105 days and aligned to sealed weeks.
select pg_temp.attest(pg_temp.org9(27),'statutory_quote','2026-03-02','{"category":"maternity","kind":"live_birth","solo":false,"fullPay":105000,"employeeContributions":9800,"sssActual":70000,"eligible":true}');
select pg_temp.attest(pg_temp.org9(27),'statutory_accrual','2026-03-02',jsonb_build_object('category','maternity','quoteDate','2026-03-02','quoteId',(select id from app.ph_payroll_attestation where organization_id=pg_temp.org9(27) and kind='statutory_quote'),'sourceDigest',repeat('7',64),'taxTreatmentVerified',true,'noDuplicateCompensation',true,'actualPaymentVerified',true,'nonExemptEmployer',true,'contributionsReviewed',true,'employeePaid',95200,'coveredFrom','2026-03-02','coveredTo','2026-06-14'));
select app.ph_post_statutory_journal(pg_temp.org9(27),pg_temp.u(2),'2026-03-02','statutory_accrual');
select pg_temp.attest(pg_temp.org9(27),'maternity_reconciliation','2026-06-14',jsonb_build_object('advanceAttestationId',(select attestation_id from app.ph_statutory_journal where organization_id=pg_temp.org9(27)),'leaveApprovalVerified',true,'noIntegratedAllowances',true,'agencyBasesReviewed',true,'leaveEvidenceReference','fictional approved statutory leave'));
select pg_temp.denied($$select app.ph_reconcile_maternity_coverage(pg_temp.org9(27),pg_temp.u(2),'2026-06-14')$$,'P0001','missing locked maternity days denied');
select set_config('request.jwt.claim.sub',pg_temp.u(1)::text,true);
do $$ declare o uuid:=pg_temp.org9(27);w date;d date;t uuid;j jsonb;begin
 for w in select date '2026-03-02'+k*7 from generate_series(0,14)k loop
 insert into app.accounting_period_manifest values(o,w,'Asia/Manila','fictional maternity roster',pg_temp.u(1),false);
 for d in select w+k from generate_series(0,6)k loop
 insert into app.accounting_roster_day values(o,w,pg_temp.u(2),d,480,0,'fictional maternity leave');
 perform app.ph_record_workday(o,w,pg_temp.u(2),d,(d+time '08:00') at time zone 'Asia/Manila',jsonb_build_object(d::text,'ordinary',(d+1)::text,'ordinary'),'fictional maternity day');
 end loop;
 update app.accounting_period_manifest set sealed=true where organization_id=o and period_start=w;
 insert into public.timesheets(organization_id,user_id,period_start,status) values(o,pg_temp.u(2),w,'locked') returning id into t;
 j:='{"classificationVersion":4,"exactOvertimeReviewSeconds":0,"payLines":[],"workedSeconds":0,"overtimeSeconds":0}';
 insert into app.accounting_submission values(o,w,pg_temp.u(2),j,t);
 insert into app.accounting_locked_snapshot values(o,w,pg_temp.u(2),j);
 insert into public.payroll_periods(organization_id,period_start,locked_by) values(o,w,pg_temp.u(1));
 end loop;
end $$;
select set_config('request.jwt.claim.sub',pg_temp.u(4)::text,true);
select pg_temp.denied($$select app.ph_reconcile_maternity_coverage(pg_temp.org9(27),pg_temp.u(2),'2026-06-14')$$,'P0001','missing monthly contribution evidence denied');
select pg_temp.attest(pg_temp.org9(27),'contribution',g::date,jsonb_build_object('allocationDate',(g+interval '1 month - 1 day')::date,'sss',30000,'philhealth',30000,'pagibig',30000)) from generate_series(date '2026-03-01',date '2026-06-01',interval '1 month')g;
select pg_temp.expect((app.ph_reconcile_maternity_coverage(pg_temp.org9(27),pg_temp.u(2),'2026-06-14')->>'coveredDays')::int=105,'all 105 maternity days reconciled');
select pg_temp.expect((app.ph_reconcile_maternity_coverage(pg_temp.org9(27),pg_temp.u(2),'2026-06-14')->>'employeeContributions')::numeric=9800,'four reviewed agency months reconcile employee deductions');
select pg_temp.expect((app.ph_reconcile_maternity_coverage(pg_temp.org9(27),pg_temp.u(2),'2026-06-14')->>'employerContributions')::numeric=15920,'four reviewed agency months employer liabilities');
select pg_temp.expect((app.ph_reconcile_maternity_coverage(pg_temp.org9(27),pg_temp.u(2),'2026-06-14')->'thirteenthCandidate'->>'remaining')::numeric=4600,'salary differential included and SSS advance excluded from 13th candidate');
select pg_temp.expect((app.ph_reconcile_maternity_coverage(pg_temp.org9(27),pg_temp.u(2),'2026-06-14')->>'finalCloseEnabled')::boolean=false,'no unsafe maternity annual close');
select set_config('request.jwt.claim.sub',pg_temp.u(1)::text,true);
select pg_temp.denied($$select app.ph_reconcile_maternity_coverage(pg_temp.org9(27),pg_temp.u(2),'2026-06-14')$$,'42501','maternity review maker denied');
select set_config('request.jwt.claim.sub',pg_temp.u(3)::text,true);
select pg_temp.denied($$select app.ph_reconcile_maternity_coverage(pg_temp.org9(27),pg_temp.u(2),'2026-06-14')$$,'42501','staff maternity review denied');
select pg_temp.expect(not has_function_privilege('authenticated','app.ph_reconcile_maternity_coverage(uuid,uuid,date)','EXECUTE'),'maternity reconciliation private');
rollback;
