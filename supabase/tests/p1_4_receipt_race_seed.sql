\set ON_ERROR_STOP on
begin;
create function pg_temp.u(i int) returns uuid language sql as $ select ('fb000000-0000-0000-0000-00000000000'||i)::uuid $;
create function pg_temp.expect(ok boolean,msg text) returns void language plpgsql as $begin if ok is distinct from true then raise exception '%',msg;end if;end $;
create function pg_temp.denied(q text,c text,msg text) returns void language plpgsql as $begin begin execute q;exception when others then if sqlstate=c then return;else raise;end if;end;raise exception '%',msg;end $;
\ir p1_2_cutoff_fixture.sql
select pg_temp.seed9(20,'monthly','2026-02-01','monthly',30000,false,'none');
select set_config('request.jwt.claim.sub',pg_temp.u(4)::text,true);
select app.ph_post_cutoff_2026(pg_temp.org9(20),pg_temp.u(2),'2026-02-01');
select pg_temp.attest(pg_temp.org9(20),'statutory_quote','2026-03-01','{"category":"maternity","kind":"live_birth","solo":false,"fullPay":100000,"employeeContributions":7000,"sssActual":70000,"eligible":true}');
select pg_temp.attest(pg_temp.org9(20),'statutory_accrual','2026-03-01',jsonb_build_object('category','maternity','quoteDate','2026-03-01','quoteId',(select id from app.ph_payroll_attestation where organization_id=pg_temp.org9(20) and kind='statutory_quote'),'sourceDigest',repeat('a',64),'taxTreatmentVerified',true,'noDuplicateCompensation',true,'actualPaymentVerified',true,'nonExemptEmployer',true,'contributionsReviewed',true,'employeePaid',93000,'coveredFrom','2026-03-01','coveredTo','2026-06-13'));
select set_config('request.jwt.claim.sub',pg_temp.u(1)::text,true);
select pg_temp.denied($$select app.ph_post_statutory_journal(pg_temp.org9(20),pg_temp.u(2),'2026-03-01','statutory_accrual')$$,'42501','maker denied statutory posting');
select set_config('request.jwt.claim.sub',pg_temp.u(4)::text,true);
select pg_temp.expect((app.ph_post_statutory_journal(pg_temp.org9(20),pg_temp.u(2),'2026-03-01','statutory_accrual')->>'salaryDifferential')::numeric=23000,'maternity differential reconciled');
select pg_temp.expect((select debit_total=93000 and credit_total=debit_total from app.ph_statutory_journal where organization_id=pg_temp.org9(20)),'advance and differential journal balanced');
select pg_temp.expect((app.ph_post_statutory_journal(pg_temp.org9(20),pg_temp.u(2),'2026-03-01','statutory_accrual')->>'journalTotal')::numeric=93000,'maternity retry idempotent');
select pg_temp.attest(pg_temp.org9(20),'sss_reimbursement','2026-06-15',jsonb_build_object('quoteDate','2026-03-01','quoteId',(select id from app.ph_payroll_attestation where organization_id=pg_temp.org9(20) and kind='statutory_quote'),'sourceDigest',repeat('b',64),'receiptVerified',true,'amount',30000));
commit;
