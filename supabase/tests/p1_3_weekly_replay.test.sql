
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

create temp table rev as select app.ph_prepare_payroll_evidence(pg_temp.org(),pg_temp.u(2),'reversal','2026-01-12','{"undispatched":true,"reason":"fictional commission correction"}','fictional reversal') id;
select set_config('request.jwt.claim.sub',pg_temp.u(4)::text,true);
select app.ph_approve_payroll_evidence(pg_temp.org(),(select id from rev),'fictional independent reversal');
select app.ph_post_canonical_reversal(pg_temp.org(),pg_temp.u(2),'2026-01-12');
select set_config('request.jwt.claim.sub',pg_temp.u(1)::text,true);
create temp table rep as select app.ph_prepare_payroll_evidence(pg_temp.org(),pg_temp.u(2),'weekly_replay','2026-01-12',
 (select payload||jsonb_build_object('supplemental',jsonb_build_array(jsonb_build_object('code','commission','amount',200,'reference','fictional corrected commission')),'originalAttestation',id,'undispatched',true,'reason','fictional correction') from app.ph_payroll_attestation where kind='week' and organization_id=pg_temp.org()),'fictional replacement') id;
select set_config('request.jwt.claim.sub',pg_temp.u(4)::text,true);
select app.ph_approve_payroll_evidence(pg_temp.org(),(select id from rep),'fictional independent replacement');
select pg_temp.expect((app.ph_replay_week_2026(pg_temp.org(),pg_temp.u(2),'2026-01-12')->>'net')::numeric=711.25,'weekly corrected net');
select pg_temp.expect((select count(*)=1 and max(revision)=2 from app.ph_effective_monetary where organization_id=pg_temp.org()),'weekly effective revision only');
select pg_temp.expect((app.ph_replay_week_2026(pg_temp.org(),pg_temp.u(2),'2026-01-12')->>'net')::numeric=711.25,'weekly replacement retry');
select pg_temp.expect((select debit_total=credit_total and debit_total=2171.25 from app.ph_payroll_journal where organization_id=pg_temp.org() and revision=2),'weekly replacement journal balances');
select pg_temp.expect(not has_function_privilege('authenticated','app.ph_replay_week_2026(uuid,uuid,date)','EXECUTE'),'weekly replay private');
select pg_temp.expect((app.ph_validate_1601c_items('{"14":1311.25,"15":0,"16":0,"17":0,"18":200,"19":600,"20":0,"21":800,"22":511.25,"23":511.25,"24":0,"25":0}')->>'22')::numeric=511.25,'1601-C Part II arithmetic');
select pg_temp.denied($$select app.ph_validate_1601c_items('{"14":1311.25,"15":0,"16":0,"17":0,"18":200,"19":600,"20":0,"21":801,"22":511.25,"23":511.25,"24":0,"25":0}')$$,'22023','invalid 1601-C total rejected');

-- Exercise actual reviewed worksheet and security, separately from final close.
savepoint worksheet;
select set_config('request.jwt.claim.sub',pg_temp.u(1)::text,true);
select app.ph_prepare_month_report(pg_temp.org(),'2026-01-01','fictional complete report after weekly correction');
select set_config('request.jwt.claim.sub',pg_temp.u(4)::text,true);
select app.ph_review_month_report(pg_temp.org(),'2026-01-01','fictional independent report review');
select set_config('request.jwt.claim.sub',pg_temp.u(1)::text,true);
create temp table form_ev as select app.ph_prepare_payroll_evidence(pg_temp.org(),pg_temp.u(2),'form1601c','2026-01-01',
 jsonb_build_object('version','1601-C-2018-ENCS','paidCompensationVerified',true,'sourcePeriods',(select source_periods from app.ph_month_report where organization_id=pg_temp.org()),'items','{"14":1311.25,"15":0,"16":0,"17":0,"18":200,"19":600,"20":0,"21":800,"22":511.25,"23":511.25,"24":0,"25":0}'::jsonb),'fictional reviewed paid compensation evidence') id;
select set_config('request.jwt.claim.sub',pg_temp.u(4)::text,true);
select app.ph_approve_payroll_evidence(pg_temp.org(),(select id from form_ev),'fictional independent form review');
select pg_temp.expect((app.ph_reviewed_1601c_worksheet(pg_temp.org(),pg_temp.u(2),'2026-01-01')->'items'->>'14')::numeric=1311.25,'reviewed form worksheet reconciles effective ledger');
select set_config('request.jwt.claim.sub',pg_temp.u(3)::text,true);
select pg_temp.denied($$select app.ph_reviewed_1601c_worksheet(pg_temp.org(),pg_temp.u(2),'2026-01-01')$$,'42501','staff worksheet denied');
rollback to worksheet;
-- Verify prior-employer refund is unchanged and annual record binds revision 2.
select set_config('request.jwt.claim.sub',pg_temp.u(1)::text,true);
select public.offboard_member((select id from public.memberships where organization_id=pg_temp.org() and user_id=pg_temp.u(2)));
insert into ev select 'annual',app.ph_prepare_payroll_evidence(pg_temp.org(),pg_temp.u(2),'annual','2026-01-12','{"reason":"termination","available":0}','fictional final employment review');
select set_config('request.jwt.claim.sub',pg_temp.u(4)::text,true);
select app.ph_approve_payroll_evidence(pg_temp.org(),(select id from ev where kind='annual'),'fictional independent check');
select pg_temp.expect((app.ph_record_annual_settlement_2026(pg_temp.org(),pg_temp.u(2),'2026-01-12')->>'refund')::numeric=1000,'weekly final refund uses effective revision and verified prior withholding');
select pg_temp.expect((select final_revision=2 from app.ph_annual_settlement where organization_id=pg_temp.org()),'weekly final settlement binds replacement revision');
rollback;
