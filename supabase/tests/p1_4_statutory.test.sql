\set ON_ERROR_STOP on
begin;
\ir p0_3_fixture.sql
\ir p1_2_cutoff_fixture.sql
select pg_temp.seed9(17,'monthly','2026-02-01','monthly',30000,false,'none');
select set_config('request.jwt.claim.sub',pg_temp.u(4)::text,true);
select app.ph_post_cutoff_2026(pg_temp.org9(17),pg_temp.u(2),'2026-02-01');
select pg_temp.attest(pg_temp.org9(17),'statutory_quote','2026-03-01','{"category":"maternity","kind":"live_birth","solo":false,"fullPay":100000,"employeeContributions":7000,"sssActual":70000,"eligible":true}');
select pg_temp.attest(pg_temp.org9(17),'statutory_accrual','2026-03-01',jsonb_build_object('category','maternity','quoteDate','2026-03-01','quoteId',(select id from app.ph_payroll_attestation where organization_id=pg_temp.org9(17) and kind='statutory_quote'),'sourceDigest',repeat('a',64),'taxTreatmentVerified',true,'noDuplicateCompensation',true,'actualPaymentVerified',true,'nonExemptEmployer',true,'contributionsReviewed',true,'employeePaid',93000,'coveredFrom','2026-03-01','coveredTo','2026-06-13'));
select set_config('request.jwt.claim.sub',pg_temp.u(1)::text,true);
select pg_temp.denied($$select app.ph_post_statutory_journal(pg_temp.org9(17),pg_temp.u(2),'2026-03-01','statutory_accrual')$$,'42501','maker denied statutory posting');
select set_config('request.jwt.claim.sub',pg_temp.u(4)::text,true);
select pg_temp.expect((app.ph_post_statutory_journal(pg_temp.org9(17),pg_temp.u(2),'2026-03-01','statutory_accrual')->>'salaryDifferential')::numeric=23000,'maternity differential reconciled');
select pg_temp.expect((select debit_total=93000 and credit_total=debit_total from app.ph_statutory_journal where organization_id=pg_temp.org9(17)),'advance and differential journal balanced');
select pg_temp.expect((app.ph_post_statutory_journal(pg_temp.org9(17),pg_temp.u(2),'2026-03-01','statutory_accrual')->>'journalTotal')::numeric=93000,'maternity retry idempotent');
select pg_temp.attest(pg_temp.org9(17),'sss_reimbursement','2026-06-15',jsonb_build_object('quoteDate','2026-03-01','quoteId',(select id from app.ph_payroll_attestation where organization_id=pg_temp.org9(17) and kind='statutory_quote'),'sourceDigest',repeat('b',64),'receiptVerified',true,'amount',30000));
select pg_temp.expect((app.ph_post_statutory_journal(pg_temp.org9(17),pg_temp.u(2),'2026-06-15','sss_reimbursement')->>'outstanding')::numeric=40000,'partial reimbursement');
select pg_temp.attest(pg_temp.org9(17),'sss_reimbursement','2026-06-16',jsonb_build_object('quoteDate','2026-03-01','quoteId',(select id from app.ph_payroll_attestation where organization_id=pg_temp.org9(17) and kind='statutory_quote'),'sourceDigest',repeat('c',64),'receiptVerified',true,'amount',40000));
select pg_temp.expect((app.ph_post_statutory_journal(pg_temp.org9(17),pg_temp.u(2),'2026-06-16','sss_reimbursement')->>'outstanding')::numeric=0,'full reimbursement clears receivable');
select pg_temp.attest(pg_temp.org9(17),'sss_reimbursement','2026-06-17',jsonb_build_object('quoteDate','2026-03-01','quoteId',(select id from app.ph_payroll_attestation where organization_id=pg_temp.org9(17) and kind='statutory_quote'),'sourceDigest',repeat('d',64),'receiptVerified',true,'amount',1));
select pg_temp.denied($$select app.ph_post_statutory_journal(pg_temp.org9(17),pg_temp.u(2),'2026-06-17','sss_reimbursement')$$,'P0001','over-reimbursement denied');
select pg_temp.denied($$select app.ph_month_report_totals(pg_temp.org9(17),'2026-03-01')$$,'P0001','incomplete maternity reporting blocked');
select pg_temp.expect((select sum((x->>'debit')::numeric-(x->>'credit')::numeric)=0 from app.ph_statutory_journal j cross join lateral jsonb_array_elements(j.lines)x where j.organization_id=pg_temp.org9(17) and x->>'account'='sss_maternity_receivable'),'SSS receivable exactly cleared');

select pg_temp.expect((app.ph_statutory_compensation_summary(pg_temp.org9(17),pg_temp.u(2),2026)->>'maternityEmployeeAlreadyPaid')::numeric=93000,'maternity paid separately from ordinary accrual');
select pg_temp.expect((app.ph_statutory_compensation_summary(pg_temp.org9(17),pg_temp.u(2),2026)->>'sssReceivable')::numeric=0,'employer reimbursement not employee compensation');
select pg_temp.expect((app.ph_statutory_compensation_summary(pg_temp.org9(17),pg_temp.u(2),2026)->>'ordinaryTaxable')::numeric=27550,'exempt maternity does not increase ordinary taxable');
select pg_temp.expect((app.ph_statutory_compensation_summary(pg_temp.org9(17),pg_temp.u(2),2026)->>'maternityCoverageIntegrated')::boolean=false,'maternity final close remains gated');
select set_config('request.jwt.claim.sub',pg_temp.u(3)::text,true);
select pg_temp.denied($$select app.ph_statutory_compensation_summary(pg_temp.org9(17),pg_temp.u(2),2026)$$,'42501','staff statutory summary denied');
select pg_temp.denied($$select app.ph_post_statutory_journal(pg_temp.org9(17),pg_temp.u(2),'2026-03-01','statutory_accrual')$$,'42501','staff statutory journal denied');
select pg_temp.expect(not has_table_privilege('authenticated','app.ph_statutory_journal','SELECT'),'statutory journal private');
select pg_temp.expect(not has_function_privilege('authenticated','app.ph_post_statutory_journal(uuid,uuid,date,text)','EXECUTE'),'statutory writer private');
rollback;
