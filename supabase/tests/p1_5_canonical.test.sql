\set ON_ERROR_STOP on
begin;
\ir p0_3_fixture.sql
\ir p1_2_cutoff_fixture.sql
select pg_temp.seed9(51,'monthly','2026-02-01','monthly',30000,false,'none');
select set_config('request.jwt.claim.sub',pg_temp.u(4)::text,true);
select app.ph_post_cutoff_2026(pg_temp.org9(51),pg_temp.u(2),'2026-02-01');
select pg_temp.expect((select j.lines=app.ph_canonical_payroll_lines(s.gross,s.employee_contributions,s.employer_contributions,s.withholding,s.net,s.evidence->'contributions') and j.debit_total=33980 and j.credit_total=33980 from app.ph_effective_monetary s join app.ph_payroll_journal j using(organization_id,period_start,user_id,revision) where s.organization_id=pg_temp.org9(51)),'canonical journal exactly matches monthly snapshot');
select pg_temp.denied($$select app.ph_canonical_payroll_lines(100,0,0,0,99,'{}')$$,'22023','net mismatch denied');
select pg_temp.denied($$select app.ph_canonical_payroll_lines(100,1,0,0,99,'{}')$$,'22023','unallocated contribution denied');
select pg_temp.denied($$select app.ph_canonical_payroll_lines(100,1,1,0,99,'{"sss":{"employee":1,"employer":1,"total":3}}')$$,'22023','false agency total denied');
select pg_temp.expect((select sum((x->>'debit')::numeric)=100 and sum((x->>'credit')::numeric)=100 from jsonb_array_elements(app.ph_canonical_payroll_lines(100,0,0,0,100,'{}'))x),'zero contributions balanced');
select pg_temp.expect(to_regclass('app.ph_money_snapshot') is null and to_regclass('app.ph_money_journal') is null,'no competing PR21 monetary tables');
do $$ declare r text;begin
foreach r in array array['anon','authenticated','service_role'] loop
perform pg_temp.expect(not has_function_privilege(r,'app.ph_canonical_payroll_lines(numeric,numeric,numeric,numeric,numeric,jsonb)','EXECUTE'),'canonical projection private');
perform pg_temp.expect(not has_table_privilege(r,'app.ph_payroll_journal','INSERT'),'canonical journal direct write denied');
end loop;end $$;
select pg_temp.expect((app.ph_review_sss_components(pg_temp.org9(51),'2026-02-01')->>'total')::numeric=4530,'SSS total from effective journal');
select pg_temp.expect((app.ph_review_sss_components(pg_temp.org9(51),'2026-02-01')->>'regular')::numeric+(app.ph_review_sss_components(pg_temp.org9(51),'2026-02-01')->>'mpf')::numeric+(app.ph_review_sss_components(pg_temp.org9(51),'2026-02-01')->>'ec')::numeric=4530,'SSS component reconciliation');
select pg_temp.denied($$select app.ph_review_sss_components(pg_temp.org9(52),'2026-02-01')$$,'42501','cross-tenant component review denied');
select set_config('request.jwt.claim.sub',pg_temp.u(3)::text,true);
select pg_temp.denied($$select app.ph_review_sss_components(pg_temp.org9(51),'2026-02-01')$$,'42501','staff component review denied');
rollback;
