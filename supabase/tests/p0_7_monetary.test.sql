
\set ON_ERROR_STOP on
begin;
\ir p0_3_fixture.sql
select app.accounting_lock(pg_temp.org(),'2025-01-06');
select pg_temp.denied($$select app.ph_post_monetary_week(pg_temp.org(),'2025-01-06',pg_temp.u(2))$$,'P0001','missing opening blocks monetary posting');
insert into app.ph_monetary_opening values(pg_temp.org(),pg_temp.u(2),2025,'2025-01-06','fictional zero opening and ordinary taxable pay only',pg_temp.u(1),pg_temp.u(4));
insert into app.ph_monthly_basis_evidence values(pg_temp.org(),pg_temp.u(2),'2025-01-01',5000,10000,5000,'2025-01-06','fictional final classified bases for month',pg_temp.u(1),pg_temp.u(4));
select pg_temp.expect((app.ph_cumulative_withholding(60000,2,1375.05,'monthly','2025-03-01')->>'withhold')::numeric=1375.05,'cumulative average uses prior withholding');
select app.ph_post_monetary_week(pg_temp.org(),'2025-01-06',pg_temp.u(2));
select pg_temp.expect((select gross=911.25 and employee_contributions=600 and employer_contributions=860 and net=311.25 and withholding=0 from app.ph_monetary_snapshot where organization_id=pg_temp.org()),'gross net and contribution amounts reconcile');
select pg_temp.expect((select debit_total=1771.25 and credit_total=debit_total from app.ph_payroll_journal where organization_id=pg_temp.org()),'journal balanced');
select pg_temp.denied($$select app.ph_post_monetary_week(pg_temp.org(),'2025-01-06',pg_temp.u(2))$$,'P0001','duplicate posting denied');
select pg_temp.denied($$update app.ph_monetary_snapshot set gross=0$$,'42501','monetary snapshot immutable');
select pg_temp.denied($$delete from app.ph_payroll_journal$$,'42501','journal immutable');
create temp table cert as select app.ph_import_2316(pg_temp.org(),pg_temp.u(2),2026,'issuer-A-001',repeat('a',64),'2026-01-01','2026-02-28',
'{"19":110000,"20":10000,"21":100000,"22":0,"23":100000,"24":0,"25A":10000,"25B":0,"26":10000,"27":0,"28":10000,"34":10000,"38":10000,"52":100000}','fictional signed source') as id;
select pg_temp.denied($$select app.ph_store_2316_envelope(pg_temp.org(),(select id from cert),repeat('b',64),decode(repeat('ab',64),'hex'),'fictional-key','fictional-envelope')$$,'22023','custody plaintext hash must match import');
select app.ph_store_2316_envelope(pg_temp.org(),(select id from cert),repeat('a',64),decode(repeat('ab',64),'hex'),'fictional-key','fictional-envelope');
select pg_temp.denied($$select app.ph_review_2316_envelope(pg_temp.org(),(select id from cert),'fictional self review')$$,'42501','custody self review denied');
select set_config('request.jwt.claim.sub',pg_temp.u(4)::text,true);
select app.ph_review_2316_envelope(pg_temp.org(),(select id from cert),'fictional independent review');
select pg_temp.expect((select count(*)=1 from app.ph_2316_custody_review),'one custody review recorded');
select pg_temp.expect(not has_table_privilege('authenticated','app.ph_2316_custody','SELECT'),'no client ciphertext read');
select pg_temp.expect(not has_function_privilege('authenticated','app.ph_post_monetary_week(uuid,date,uuid)','EXECUTE'),'no public monetary posting');
rollback;
