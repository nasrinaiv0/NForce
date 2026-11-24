
\set ON_ERROR_STOP on
begin;
\ir p0_3_fixture.sql
select pg_temp.expect((select count(*)>=4 from app.accounting_lifecycle_event where organization_id=pg_temp.org()),'lifecycle writes capture evidence');
select pg_temp.denied($$ update app.accounting_lifecycle_event set status='ended' where organization_id=pg_temp.org() $$,'42501','lifecycle evidence immutable');
insert into auth.users(id) values(pg_temp.u(5));
insert into public.memberships(organization_id,user_id,status,reports_to)
values(pg_temp.org(),pg_temp.u(5),'active',(select id from public.memberships where organization_id=pg_temp.org() and user_id=pg_temp.u(1)));
create temp table ingested as select id,app.accounting_ingest_lifecycle(pg_temp.org(),id) as effective_on from app.accounting_lifecycle_event where organization_id=pg_temp.org() and user_id=pg_temp.u(5);
select pg_temp.expect((select effective_on=app.accounting_ingest_lifecycle(pg_temp.org(),id) from ingested),'historical ingestion retry idempotent');
select pg_temp.expect((select count(*)=1 from app.accounting_employee_history where organization_id=pg_temp.org() and user_id=pg_temp.u(5)),'no synthetic prehire history');
update public.timesheets set status='returned' where organization_id=pg_temp.org() and user_id=pg_temp.u(2);
select public.offboard_member((select id from public.memberships where organization_id=pg_temp.org() and user_id=pg_temp.u(2)));
select app.accounting_prepare_departed(pg_temp.org(),'2025-01-06',pg_temp.u(2),'fictional final reconciliation evidence');
select pg_temp.denied($$ select app.accounting_approve_departed(pg_temp.org(),'2025-01-06',pg_temp.u(2)) $$,'42501','departed reconciliation requires independent reviewer');
select set_config('request.jwt.claim.sub',pg_temp.u(4)::text,true);
select app.accounting_approve_departed(pg_temp.org(),'2025-01-06',pg_temp.u(2));
select pg_temp.expect((select status='approved' and worked_minutes=540 from public.timesheets where organization_id=pg_temp.org() and user_id=pg_temp.u(2)),'departed employee hours approved without impersonation');
select pg_temp.expect((select status='ended' from public.memberships where organization_id=pg_temp.org() and user_id=pg_temp.u(2)),'departed employee remains offboarded');
select app.accounting_lock(pg_temp.org(),'2025-01-06');
select pg_temp.denied($$ insert into public.attendance_events(organization_id,user_id,type,occurred_at,source,idempotency_key) values(pg_temp.org(),pg_temp.u(2),'clock_out','2025-01-07 01:00Z','correction','p04-locked-correction') $$,'42501','locked correction requires adjustment');
select pg_temp.expect(not has_function_privilege('authenticated','app.accounting_ingest_lifecycle(uuid,bigint)','EXECUTE'),'private ingestion inaccessible');
select pg_temp.expect(not has_function_privilege('authenticated','app.accounting_approve_departed(uuid,date,uuid)','EXECUTE'),'private departed approval inaccessible');
rollback;
