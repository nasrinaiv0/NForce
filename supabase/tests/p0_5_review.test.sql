
\set ON_ERROR_STOP on
begin;
\ir p0_3_fixture.sql
select app.accounting_lock(pg_temp.org(),'2025-01-06');
select pg_temp.denied($$ select public.accounting_review_snapshot(pg_temp.org(),'2025-01-06','organization') $$,'42501','review is disabled by default');
insert into app.accounting_review_access(organization_id,evidence_reference,enabled_by,expires_at) values(pg_temp.org(),'fictional acceptance evidence',pg_temp.u(1),now()+interval '1 hour');
select pg_temp.expect((public.accounting_review_snapshot(pg_temp.org(),'2025-01-06','organization')->>'workedMinutes')::int=540,'locked original server totals');
select pg_temp.expect((public.accounting_review_snapshot(pg_temp.org(),'2025-01-06','organization')->>'employeeCount')::int=1,'only historical locked employee counted');
select set_config('request.jwt.claim.sub',pg_temp.u(2)::text,true);
select pg_temp.denied($$ select public.accounting_review_snapshot(pg_temp.org(),'2025-01-06','organization') $$,'42501','staff cannot read organization aggregate');
select pg_temp.expect((public.accounting_review_snapshot(pg_temp.org(),'2025-01-06','self')->>'workedMinutes')::int=540,'staff reads only own locked original');
select pg_temp.denied($$ select public.accounting_review_snapshot('fc100000-0000-0000-0000-000000000002','2025-01-06','self') $$,'42501','foreign tenant denied');
select set_config('request.jwt.claim.sub',pg_temp.u(1)::text,true);
select pg_temp.denied($$ select app.accounting_prepare_ingestion(pg_temp.org(),array[-1]::bigint[],'fixture reference','p05-invalid-key') $$,'22023','foreign or nonexistent lifecycle event rejected');
create temp table batch as select app.accounting_prepare_ingestion(pg_temp.org(),array[(select min(id) from app.accounting_lifecycle_event where organization_id=pg_temp.org())],'fixture reference','p05-test-key') as id;
select pg_temp.denied($$ select app.accounting_approve_ingestion(pg_temp.org(),(select id from batch)) $$,'42501','ingestion proposer cannot self approve');
-- Independent reviewer applies a new captured event, without historical fabrication.
insert into auth.users(id) values(pg_temp.u(5));
insert into public.memberships(organization_id,user_id,status,reports_to) values(pg_temp.org(),pg_temp.u(5),'active',(select id from public.memberships where organization_id=pg_temp.org() and user_id=pg_temp.u(1)));
insert into public.membership_roles(membership_id,role_id) select m.id,r.id from public.memberships m cross join public.roles r where m.organization_id=pg_temp.org() and m.user_id=pg_temp.u(3) and r.organization_id is null and r.key='owner';
create temp table approved_batch as select app.accounting_prepare_ingestion(pg_temp.org(),array[(select id from app.accounting_lifecycle_event where organization_id=pg_temp.org() and user_id=pg_temp.u(5))],'fictional reviewed event','p05-approve-key') as id;
select set_config('request.jwt.claim.sub',pg_temp.u(3)::text,true);
select app.accounting_approve_ingestion(pg_temp.org(),(select id from approved_batch));
select pg_temp.expect((select count(*)=1 from app.accounting_employee_history where organization_id=pg_temp.org() and user_id=pg_temp.u(5)),'independent batch approval ingests observed record');
select pg_temp.expect((select count(*)=1 from app.accounting_ingestion_batch_decision where batch_id=(select id from approved_batch)),'one immutable batch approval');
select pg_temp.expect(not has_function_privilege('authenticated','app.accounting_approve_ingestion(uuid,uuid)','EXECUTE'),'private ingestion remains inaccessible');
select pg_temp.expect(not has_function_privilege('anon','public.accounting_review_snapshot(uuid,date,text)','EXECUTE'),'anonymous review denied');
select pg_temp.expect(not has_function_privilege('authenticated','public.lock_payroll_period(uuid,date)','EXECUTE'),'legacy payroll write gate preserved');
rollback;
