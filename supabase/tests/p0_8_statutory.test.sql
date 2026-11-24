
\set ON_ERROR_STOP on
begin;
\ir p0_8_fixture.sql
select app.accounting_lock(pg_temp.org(),'2026-01-12');
select pg_temp.expect((app.ph_contribution_candidate('philhealth',100000,'2026-11-01')->>'total')::numeric=5000,'2026 PH ceiling');
select pg_temp.expect((app.ph_contribution_candidate('philhealth',5000,'2026-01-01')->>'employee')::numeric=250,'2026 PH floor');
select app.ph_open_benefit_year(pg_temp.org(),pg_temp.u(2),'2026-01-05','{}',0,'monthly','fictional reviewed opening');
select app.ph_post_benefit(pg_temp.org(),pg_temp.u(2),'p08-rice-001','2026-01-12','rice',200,null,null,'fictional receipt');
create temp table cert as select app.ph_import_2316(pg_temp.org(),pg_temp.u(2),2026,'issuer-P08-001',repeat('a',64),'2026-01-01','2026-01-11','{"19":11000,"20":1000,"21":10000,"22":0,"23":10000,"24":0,"25A":1000,"25B":0,"26":1000,"27":0,"28":1000,"34":1000,"38":1000,"52":10000}','fictional prior source') as id;
select app.ph_store_2316_envelope(pg_temp.org(),(select id from cert),repeat('a',64),decode(repeat('ab',64),'hex'),'fictional-key','fictional-envelope');
select set_config('request.jwt.claim.sub',pg_temp.u(4)::text,true);
select app.ph_review_2316(pg_temp.org(),(select id from cert),true,'fictional independent form review');
select app.ph_review_2316_envelope(pg_temp.org(),(select id from cert),'fictional independent custody review');
select set_config('request.jwt.claim.sub',pg_temp.u(1)::text,true);
create temp table ev(kind text,id uuid);
insert into ev select 'opening',app.ph_prepare_payroll_evidence(pg_temp.org(),pg_temp.u(2),'opening','2026-01-01',jsonb_build_object('method','cumulative','previousPeriods',1,'certificates',jsonb_build_array((select id::text from cert)),'currentStart','2026-01-12','firstPeriod','2026-01-12'),'fictional opening coverage');
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
select pg_temp.expect((app.ph_prior_employer_2026(pg_temp.org(),pg_temp.u(2))->>'taxable')::numeric=10000,'prior employer own taxable fields reconciled');
select pg_temp.expect((app.ph_prior_employer_2026(pg_temp.org(),pg_temp.u(2))->>'withheld')::numeric=1000,'prior employer own withheld fields reconciled');
select pg_temp.denied($$select app.ph_get_reviewed_envelope(pg_temp.org(),(select id from cert))$$,'42501','missing retention evidence denies retrieval');
insert into ev select 'custody_policy',app.ph_prepare_payroll_evidence(pg_temp.org(),pg_temp.u(2),'custody_policy','2026-01-12',jsonb_build_object('importId',(select id from cert),'retainUntil','2030-12-31','legalHold',false),'fictional retention review');
select set_config('request.jwt.claim.sub',pg_temp.u(4)::text,true);
select app.ph_approve_payroll_evidence(pg_temp.org(),(select id from ev where kind='custody_policy'),'fictional independent retention check');
select set_config('request.jwt.claim.sub',pg_temp.u(1)::text,true);
select app.ph_register_custody_policy(pg_temp.org(),(select id from cert),'2026-01-12');
select pg_temp.expect((app.ph_get_reviewed_envelope(pg_temp.org(),(select id from cert))->>'plaintextSha256')=repeat('a',64),'reviewed private custody retrieval');
select public.offboard_member((select id from public.memberships where organization_id=pg_temp.org() and user_id=pg_temp.u(2)));
insert into ev select 'annual',app.ph_prepare_payroll_evidence(pg_temp.org(),pg_temp.u(2),'annual','2026-01-12','{"reason":"termination","available":0}','fictional final employment review');
select set_config('request.jwt.claim.sub',pg_temp.u(4)::text,true);
select app.ph_approve_payroll_evidence(pg_temp.org(),(select id from ev where kind='annual'),'fictional independent check');
select set_config('request.jwt.claim.sub',pg_temp.u(1)::text,true);
select pg_temp.expect((app.ph_record_annual_settlement_2026(pg_temp.org(),pg_temp.u(2),'2026-01-12')->>'refund')::numeric=1000,'annual settlement uses verified prior withholding');
select pg_temp.expect((select count(*)=1 from app.ph_annual_settlement),'annual settlement persisted once');
select pg_temp.denied($$update app.ph_annual_settlement set result='{}'$$,'42501','annual settlement immutable');
\ir p0_9_acceptance.sql
rollback;
