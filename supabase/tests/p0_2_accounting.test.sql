
\set ON_ERROR_STOP on
begin;
create function pg_temp.expect(ok boolean,label text) returns void language plpgsql as $$
begin if ok is distinct from true then raise exception 'FAILED: %',label; end if; raise notice 'ok - %',label; end $$;
create function pg_temp.denied(stmt text,state text,label text) returns void language plpgsql as $$
begin execute stmt; raise exception 'no error: %',label;
exception when others then if sqlstate<>state then raise exception 'FAILED: % (% %)',label,sqlstate,sqlerrm; end if; raise notice 'ok - %',label; end $$;
create function pg_temp.org() returns uuid language sql as $$ select 'fa100000-0000-0000-0000-000000000001'::uuid $$;
create function pg_temp.u(i int) returns uuid language sql as $$ select ('fa000000-0000-0000-0000-00000000000'||i)::uuid $$;
insert into auth.users(id) select pg_temp.u(i) from generate_series(1,4) i;
insert into public.organizations(id,name,time_zone) values(pg_temp.org(),'Fictional P0.2','Asia/Manila');
insert into public.memberships(organization_id,user_id,status) select pg_temp.org(),pg_temp.u(i),'active' from generate_series(1,4)i;
update public.memberships set reports_to=(select id from public.memberships where user_id=pg_temp.u(1)) where user_id<>pg_temp.u(1);
insert into public.membership_roles(membership_id,role_id)
select m.id,r.id from public.memberships m join public.roles r on r.organization_id is null
and r.key=case when m.user_id=pg_temp.u(1) then 'owner' else 'staff' end
where m.organization_id=pg_temp.org();
-- Employee 3 has no punches but is historically eligible; 4 is excluded.
insert into app.accounting_period_manifest values(pg_temp.org(),'2025-01-06','Asia/Manila','fixture-v1',pg_temp.u(1),false);
insert into app.accounting_roster_day values
(pg_temp.org(),'2025-01-06',pg_temp.u(2),'2025-01-06',480,0,'fixture-policy'),
(pg_temp.org(),'2025-01-06',pg_temp.u(3),'2025-01-07',480,0,'fixture-policy');
update app.accounting_period_manifest set sealed=true where organization_id=pg_temp.org();
select pg_temp.denied($$ insert into app.accounting_roster_day values(pg_temp.org(),'2025-01-06',pg_temp.u(4),'2025-01-06',480,0,'x') $$,'42501','sealed roster cannot change');
insert into public.attendance_events(organization_id,user_id,type,occurred_at,source,idempotency_key) values
(pg_temp.org(),pg_temp.u(2),'clock_in','2025-01-06 14:00Z','mobile','p02-clock-in'),
(pg_temp.org(),pg_temp.u(2),'break_start','2025-01-06 18:00Z','mobile','p02-break-in'),
(pg_temp.org(),pg_temp.u(2),'break_end','2025-01-06 19:00Z','mobile','p02-break-out'),
(pg_temp.org(),pg_temp.u(2),'clock_out','2025-01-07 00:00Z','mobile','p02-clock-out');
-- 10 elapsed hours minus one hour break = 540; 60 OT.
select pg_temp.expect((app.accounting_reconcile(pg_temp.org(),'2025-01-06',pg_temp.u(2))->>'worked')::int=540,'overnight punch replay subtracts break');
select pg_temp.expect((app.accounting_reconcile(pg_temp.org(),'2025-01-06',pg_temp.u(2))->>'unapprovedOvertime')::int=60,'unapproved overtime visible');
select pg_temp.expect((app.accounting_reconcile(pg_temp.org(),'2025-01-06',pg_temp.u(3))->>'worked')::int=0,'zero-work eligible employee still included');
select pg_temp.denied($$ select app.accounting_reconcile(pg_temp.org(),'2025-01-06',pg_temp.u(4)) $$,'P0001','excluded historical employee rejected');
select set_config('request.jwt.claim.sub',pg_temp.u(2)::text,true);
select public.submit_request(pg_temp.org(),'overtime','{"date":"2025-01-06","minutes":60}');
select set_config('request.jwt.claim.sub',pg_temp.u(1)::text,true);
select public.decide_request((select id from public.approval_requests where organization_id=pg_temp.org() and kind='overtime'),'approve');
select pg_temp.expect((app.accounting_reconcile(pg_temp.org(),'2025-01-06',pg_temp.u(2))->>'approvedOvertime')::int=60,'approved OT reconciles actual minutes');
select set_config('request.jwt.claim.sub',pg_temp.u(2)::text,true);
select pg_temp.denied($$ select public.submit_request(pg_temp.org(),'timesheet','{"periodStart":"2025-01-06","minutes":99999}') $$,'42501','generic timesheet request remains gated');
select app.accounting_submit(pg_temp.org(),'2025-01-06');
select pg_temp.expect((select worked_minutes=540 and overtime_minutes=60 from public.timesheets where organization_id=pg_temp.org() and user_id=pg_temp.u(2)),'submission stores only calculated totals');
select set_config('request.jwt.claim.sub',pg_temp.u(1)::text,true);
select public.decide_request((select id from public.approval_requests where organization_id=pg_temp.org() and kind='timesheet' and requester_id=pg_temp.u(2)),'approve');
select pg_temp.denied($$ select app.accounting_lock(pg_temp.org(),'2025-01-06') $$,'P0001','missing eligible zero-work sheet blocks lock');
select pg_temp.expect(not exists(select 1 from app.accounting_locked_snapshot where organization_id=pg_temp.org()),'failed lock leaves no partial snapshot');
select set_config('request.jwt.claim.sub',pg_temp.u(3)::text,true);
select app.accounting_submit(pg_temp.org(),'2025-01-06');
select set_config('request.jwt.claim.sub',pg_temp.u(1)::text,true);
select public.decide_request((select id from public.approval_requests where organization_id=pg_temp.org() and kind='timesheet' and requester_id=pg_temp.u(3)),'approve');
select app.accounting_lock(pg_temp.org(),'2025-01-06');
select pg_temp.expect((select count(*)=2 from app.accounting_locked_snapshot where organization_id=pg_temp.org()),'atomic lock stores two immutable snapshots');
select pg_temp.expect((select count(*)=2 from public.timesheets where organization_id=pg_temp.org() and status='locked'),'all eligible sheets locked');
select pg_temp.denied($$ select app.accounting_lock(pg_temp.org(),'2025-01-06') $$,'P0001','repeat lock rejected');
select pg_temp.denied($$ update app.accounting_locked_snapshot set reconciliation='{}' where organization_id=pg_temp.org() $$,'42501','locked reconciliation immutable');
select pg_temp.expect(not has_function_privilege('authenticated','app.accounting_submit(uuid,date)','EXECUTE'),'candidate submission inaccessible to API role');
select pg_temp.expect(not has_function_privilege('authenticated','app.accounting_lock(uuid,date)','EXECUTE'),'candidate lock inaccessible to API role');
select pg_temp.expect(not has_function_privilege('authenticated','public.submit_timesheet(uuid,date,integer,integer)','EXECUTE'),'legacy public submission remains gated');
select pg_temp.expect(not has_function_privilege('authenticated','public.lock_payroll_period(uuid,date)','EXECUTE'),'legacy public lock remains gated');
rollback;
