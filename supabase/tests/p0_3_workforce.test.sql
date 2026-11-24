
\set ON_ERROR_STOP on
begin;
\ir p0_3_fixture.sql
select pg_temp.expect((select (reconciliation->>'classificationVersion')::int=3 from app.accounting_submission where organization_id=pg_temp.org()),'server submission includes premium policy version');
select pg_temp.expect((select (l->>'minutes')::int=420 and (l->>'multiplier')::numeric=2.2 from app.accounting_submission s cross join lateral jsonb_array_elements(s.reconciliation->'payLines') l where s.organization_id=pg_temp.org() and l->>'code'='RH_ND'),'420 holiday night minutes at fixture rate');
select pg_temp.expect((select (l->>'minutes')::int=60 and (l->>'multiplier')::numeric=2 from app.accounting_submission s cross join lateral jsonb_array_elements(s.reconciliation->'payLines') l where s.organization_id=pg_temp.org() and l->>'code'='RH'),'60 ordinary holiday minutes');
select pg_temp.expect((select (l->>'minutes')::int=60 and (l->>'multiplier')::numeric=2.6 from app.accounting_submission s cross join lateral jsonb_array_elements(s.reconciliation->'payLines') l where s.organization_id=pg_temp.org() and l->>'code'='RH_OT'),'60 holiday overtime minutes');
select pg_temp.denied($$ select app.accounting_record_employee(pg_temp.org(),pg_temp.u(2),'2025-01-03',true,'09:00','18:00',array[6,7]::smallint[],'retroactive edit') $$,'42501','retroactive history cannot alter sealed roster');
select app.accounting_lock(pg_temp.org(),'2025-01-06');
create temp table adjustment_id as select app.accounting_propose_adjustment(pg_temp.org(),'2025-01-06',pg_temp.u(2),'RH_ND',-15,'Verified correction of minutes','fictional ticket','p03-adjust-key') as id;
select pg_temp.expect((select id=app.accounting_propose_adjustment(pg_temp.org(),'2025-01-06',pg_temp.u(2),'RH_ND',-15,'Verified correction of minutes','fictional ticket','p03-adjust-key') from adjustment_id),'identical proposal retry idempotent');
select pg_temp.denied($$ select app.accounting_decide_adjustment((select id from adjustment_id),true,'Proposer cannot approve') $$,'42501','dual control rejects self approval');
select set_config('request.jwt.claim.sub',pg_temp.u(4)::text,true);
select app.accounting_decide_adjustment((select id from adjustment_id),true,'Independent evidence review');
select pg_temp.expect((select count(*)=1 from app.accounting_adjustment_decision where approved),'one immutable approved adjustment');
select pg_temp.expect((select (l->>'minutes')::int=420 from app.accounting_locked_snapshot s cross join lateral jsonb_array_elements(s.reconciliation->'payLines') l where s.organization_id=pg_temp.org() and l->>'code'='RH_ND'),'adjustment preserves original locked snapshot');
select pg_temp.denied($$ update app.accounting_adjustment_decision set approved=false $$,'42501','adjustment decision immutable');
select pg_temp.expect(not has_function_privilege('authenticated','app.accounting_materialize_week(uuid,date,text)','EXECUTE'),'private materializer not callable by clients');
select pg_temp.expect(not has_function_privilege('authenticated','app.accounting_decide_adjustment(uuid,boolean,text)','EXECUTE'),'private adjustments not callable by clients');
select pg_temp.expect(not has_function_privilege('authenticated','public.lock_payroll_period(uuid,date)','EXECUTE'),'public payroll gate preserved');
rollback;
