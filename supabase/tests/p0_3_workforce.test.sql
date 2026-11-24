
\set ON_ERROR_STOP on
begin;
\ir p0_3_fixture.sql
select pg_temp.expect((select (reconciliation->>'classificationVersion')::int=4 from app.accounting_submission where organization_id=pg_temp.org()),'server submission includes premium policy version');
select pg_temp.expect((select sum((l->>'seconds')::numeric)=7200 and min((l->>'multiplier')::numeric)=2.2 from app.accounting_submission s cross join lateral jsonb_array_elements(s.reconciliation->'payLines') l where s.organization_id=pg_temp.org() and l->>'code'='RH_ND'),'two hours holiday ND before midnight');
select pg_temp.expect((select sum((l->>'seconds')::numeric)=18000 from app.accounting_submission s cross join lateral jsonb_array_elements(s.reconciliation->'payLines') l where s.organization_id=pg_temp.org() and l->>'code'='REG_ND'),'five hours ordinary ND after midnight excluding break');
select pg_temp.expect((select sum((l->>'seconds')::numeric)=3600 and min((l->>'multiplier')::numeric)=1.25 from app.accounting_submission s cross join lateral jsonb_array_elements(s.reconciliation->'payLines') l where s.organization_id=pg_temp.org() and l->>'code'='REG_OT'),'ordinary OT after midnight');
select pg_temp.denied($$ update app.ph_workday_evidence set source_reference='retro edit' $$,'42501','sealed evidence immutable');
select app.accounting_lock(pg_temp.org(),'2025-01-06');
create temp table adjustment_id as select app.accounting_propose_adjustment(pg_temp.org(),'2025-01-06',pg_temp.u(2),'RH_ND',-15,'Verified correction of minutes','fictional ticket','p03-adjust-key') as id;
select pg_temp.expect((select id=app.accounting_propose_adjustment(pg_temp.org(),'2025-01-06',pg_temp.u(2),'RH_ND',-15,'Verified correction of minutes','fictional ticket','p03-adjust-key') from adjustment_id),'identical proposal retry idempotent');
select pg_temp.denied($$ select app.accounting_decide_adjustment((select id from adjustment_id),true,'Proposer cannot approve') $$,'42501','dual control rejects self approval');
select set_config('request.jwt.claim.sub',pg_temp.u(4)::text,true);
select app.accounting_decide_adjustment((select id from adjustment_id),true,'Independent evidence review');
select pg_temp.expect((select count(*)=1 from app.accounting_adjustment_decision where approved),'one immutable approved adjustment');
select pg_temp.expect((select (l->>'seconds')::numeric=7200 from app.accounting_locked_snapshot s cross join lateral jsonb_array_elements(s.reconciliation->'payLines') l where s.organization_id=pg_temp.org() and l->>'code'='RH_ND'),'adjustment preserves original locked snapshot');
select pg_temp.denied($$ update app.accounting_adjustment_decision set approved=false $$,'42501','adjustment decision immutable');
select pg_temp.expect(not has_function_privilege('authenticated','app.ph_record_workday(uuid,date,uuid,date,timestamptz,jsonb,text)','EXECUTE'),'private workday attestation not callable by clients');
select pg_temp.expect(not has_function_privilege('authenticated','app.accounting_decide_adjustment(uuid,boolean,text)','EXECUTE'),'private adjustments not callable by clients');
select pg_temp.expect(not has_function_privilege('authenticated','public.lock_payroll_period(uuid,date)','EXECUTE'),'public payroll gate preserved');
rollback;
