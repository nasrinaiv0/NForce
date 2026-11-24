
-- Fictional committed fixture when invoked by the multi-session runner.
create function pg_temp.expect(ok boolean,label text) returns void language plpgsql as $$
begin if ok is distinct from true then raise exception 'FAILED: %',label; end if; raise notice 'ok - %',label; end $$;
create function pg_temp.denied(stmt text,state text,label text) returns void language plpgsql as $$
begin execute stmt; raise exception 'no error: %',label;
exception when others then if sqlstate<>state then raise exception 'FAILED: % (% %)',label,sqlstate,sqlerrm; end if; raise notice 'ok - %',label; end $$;
create function pg_temp.org() returns uuid language sql as $$ select 'fb100000-0000-0000-0000-000000000001'::uuid $$;
create function pg_temp.u(i int) returns uuid language sql as $$ select ('fb000000-0000-0000-0000-00000000000'||i)::uuid $$;
insert into auth.users(id) select pg_temp.u(i) from generate_series(1,4)i;
insert into public.organizations(id,name,time_zone) values(pg_temp.org(),'Fictional P0.3','Asia/Manila');
insert into public.memberships(organization_id,user_id,status) select pg_temp.org(),pg_temp.u(i),'active' from generate_series(1,4)i;
update public.memberships set reports_to=(select id from public.memberships where user_id=pg_temp.u(1)) where user_id<>pg_temp.u(1);
insert into public.membership_roles(membership_id,role_id)
select m.id,r.id from public.memberships m join public.roles r on r.organization_id is null
and r.key=case when m.user_id=pg_temp.u(1) then 'owner' when m.user_id=pg_temp.u(4) then 'payroll' else 'staff' end
where m.organization_id=pg_temp.org();
select set_config('request.jwt.claim.sub',pg_temp.u(1)::text,false);
-- Canonical employment history; no second eligibility table. Attested fictional roster.
insert into app.ph_employment_history(organization_id,user_id,effective_on,recorded_at,status,pay_basis,rate_php,site_reference,wage_order_reference,evidence_reference,recorded_by)
select pg_temp.org(),pg_temp.u(i),'2026-01-01','2026-01-01Z',case when i=2 then 'employed' else 'separated' end,
case when i=2 then 'daily' end,case when i=2 then 600 end,case when i=2 then 'site' end,case when i=2 then 'wage' end,'fixture history',pg_temp.u(1)
from generate_series(1,4)i;
insert into app.ph_employment_history values(pg_temp.org(),pg_temp.u(2),'2026-01-13','2026-01-13Z','separated',null,null,null,null,'fixture separation',pg_temp.u(1));
insert into app.accounting_period_manifest values(pg_temp.org(),'2026-01-12','Asia/Manila','attested fictional roster',pg_temp.u(1),false);
insert into app.accounting_roster_day values(pg_temp.org(),'2026-01-12',pg_temp.u(2),'2026-01-12',480,0,'fixture policy');
select app.ph_record_workday(pg_temp.org(),'2026-01-12',pg_temp.u(2),'2026-01-12','2026-01-12 22:00+08','{"2026-01-12":"regular_holiday","2026-01-13":"ordinary"}','fixture attested calendar and workday');
update app.accounting_period_manifest set sealed=true where organization_id=pg_temp.org();
select pg_temp.expect((select count(*)=1 from app.ph_workday_evidence where organization_id=pg_temp.org()),'canonical historical workday attested');
insert into public.attendance_events(organization_id,user_id,type,occurred_at,source,idempotency_key) values
(pg_temp.org(),pg_temp.u(2),'clock_in','2026-01-12 14:00Z','mobile','p03-clock-in'),
(pg_temp.org(),pg_temp.u(2),'break_start','2026-01-12 18:00Z','mobile','p03-break-in'),
(pg_temp.org(),pg_temp.u(2),'break_end','2026-01-12 19:00Z','mobile','p03-break-out'),
(pg_temp.org(),pg_temp.u(2),'clock_out','2026-01-13 00:00Z','mobile','p03-clock-out');
select set_config('request.jwt.claim.sub',pg_temp.u(2)::text,false);
select public.submit_request(pg_temp.org(),'overtime','{"date":"2026-01-12","minutes":60}');
select set_config('request.jwt.claim.sub',pg_temp.u(1)::text,false);
select public.decide_request((select id from public.approval_requests where organization_id=pg_temp.org() and kind='overtime'),'approve');
select set_config('request.jwt.claim.sub',pg_temp.u(2)::text,false);
select app.accounting_submit(pg_temp.org(),'2026-01-12');
select set_config('request.jwt.claim.sub',pg_temp.u(1)::text,false);
select public.decide_request((select id from public.approval_requests where organization_id=pg_temp.org() and kind='timesheet'),'approve');
