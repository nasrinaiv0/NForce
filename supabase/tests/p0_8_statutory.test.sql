
\set ON_ERROR_STOP on
begin;
\ir p0_8_fixture.sql
select app.accounting_lock(pg_temp.org(),'2026-01-12');
select pg_temp.expect((app.ph_contribution_candidate('philhealth',100000,'2026-11-01')->>'total')::numeric=5000,'2026 PH ceiling');
select pg_temp.expect((app.ph_contribution_candidate('philhealth',5000,'2026-01-01')->>'employee')::numeric=250,'2026 PH floor');
select app.ph_open_benefit_year(pg_temp.org(),pg_temp.u(2),'2026-01-05','{}',0,'monthly','fictional reviewed opening');
select app.ph_post_benefit(pg_temp.org(),pg_temp.u(2),'p08-rice-001','2026-01-12','rice',200,null,null,'fictional receipt');
create temp table ev(kind text,id uuid);
insert into ev select 'opening',app.ph_prepare_payroll_evidence(pg_temp.org(),pg_temp.u(2),'opening','2026-01-01','{"method":"weekly","previousPeriods":0,"certificates":[],"currentStart":"2026-01-12","firstPeriod":"2026-01-12"}','fictional opening coverage');
insert into ev select 'month',app.ph_prepare_payroll_evidence(pg_temp.org(),pg_temp.u(2),'month','2026-01-01','{"sss":5000,"philhealth":10000,"pagibig":5000,"allocationPeriod":"2026-01-12"}','fictional monthly allocation');
insert into ev select 'week',app.ph_prepare_payroll_evidence(pg_temp.org(),pg_temp.u(2),'week','2026-01-12','{"coverage":"ordinary-rank-and-file-taxable-complete","nonwork":[],"supplemental":[{"code":"commission","amount":100,"reference":"fictional commission"}]}','fictional complete pay week');
select pg_temp.denied($$select app.ph_approve_payroll_evidence(pg_temp.org(),(select id from ev where kind='opening'),'self approval denied')$$,'42501','maker cannot check own evidence');
select set_config('request.jwt.claim.sub',pg_temp.u(4)::text,true);
select app.ph_approve_payroll_evidence(pg_temp.org(),id,'fictional independent check') from ev order by kind;
select set_config('request.jwt.claim.sub',pg_temp.u(1)::text,true);
select app.ph_post_monetary_week_2026(pg_temp.org(),'2026-01-12',pg_temp.u(2));
select pg_temp.expect((select gross=1211.25 and exempt=200 and employee_contributions=600 and taxable=411.25 and net=611.25 from app.ph_monetary_snapshot where organization_id=pg_temp.org()),'2026 gross taxable benefits and net reconcile');
select pg_temp.expect((select debit_total=2071.25 and credit_total=debit_total from app.ph_payroll_journal where organization_id=pg_temp.org()),'2026 journal balanced');
select pg_temp.denied($$select app.ph_post_benefit(pg_temp.org(),pg_temp.u(2),'p08-rice-002','2026-01-13','rice',100,null,null,'fictional late receipt')$$,'42501','late benefits blocked after snapshot');
select pg_temp.denied($$select app.ph_post_monetary_week_2026(pg_temp.org(),'2026-01-12',pg_temp.u(2))$$,'P0001','duplicate payroll rejected');
select pg_temp.expect(not has_function_privilege('authenticated','app.ph_approve_payroll_evidence(uuid,uuid,text)','EXECUTE'),'approval stays private');
select pg_temp.expect(not has_function_privilege('authenticated','app.ph_get_reviewed_envelope(uuid,uuid)','EXECUTE'),'envelope retrieval stays private');
rollback;
