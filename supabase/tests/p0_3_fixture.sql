
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
-- Explicit historical coverage; owner and payroll are non-eligible in this fixture.
select app.accounting_record_employee(pg_temp.org(),pg_temp.u(i),'2025-01-01',i=2,'22:00','08:00',array[6,7]::smallint[],'fixture employment record')
from generate_series(1,4)i;
select app.accounting_record_employee(pg_temp.org(),pg_temp.u(2),'2025-01-07',false,'22:00','08:00',array[6,7]::smallint[],'fixture termination');
select app.accounting_record_policy(pg_temp.org(),'2025-01-01','Asia/Manila',480,0,1320,360,1.1,
'{"REG":1,"RD":1.3,"SH":1.3,"SH_RD":1.5,"RH":2,"RH_RD":2.6}',
'{"REG":1.25,"RD":1.3,"SH":1.3,"SH_RD":1.3,"RH":1.3,"RH_RD":1.3}','fictional rates, not legal advice');
select app.accounting_record_calendar(pg_temp.org(),'2025-01-06'::date+i,case when i=0 then 'regular' else 'ordinary' end,'fixture holiday calendar')
from generate_series(0,6)i;
select app.accounting_materialize_week(pg_temp.org(),'2025-01-06','attested fictional complete roster');
select pg_temp.expect((select count(*)=1 from app.accounting_roster_day where organization_id=pg_temp.org()),'effective-dated eligibility retains historical day and excludes future dates');
insert into public.attendance_events(organization_id,user_id,type,occurred_at,source,idempotency_key) values
(pg_temp.org(),pg_temp.u(2),'clock_in','2025-01-06 14:00Z','mobile','p03-clock-in'),
(pg_temp.org(),pg_temp.u(2),'break_start','2025-01-06 18:00Z','mobile','p03-break-in'),
(pg_temp.org(),pg_temp.u(2),'break_end','2025-01-06 19:00Z','mobile','p03-break-out'),
(pg_temp.org(),pg_temp.u(2),'clock_out','2025-01-07 00:00Z','mobile','p03-clock-out');
select set_config('request.jwt.claim.sub',pg_temp.u(2)::text,false);
select public.submit_request(pg_temp.org(),'overtime','{"date":"2025-01-06","minutes":60}');
select set_config('request.jwt.claim.sub',pg_temp.u(1)::text,false);
select public.decide_request((select id from public.approval_requests where organization_id=pg_temp.org() and kind='overtime'),'approve');
select set_config('request.jwt.claim.sub',pg_temp.u(2)::text,false);
select app.accounting_submit(pg_temp.org(),'2025-01-06');
select set_config('request.jwt.claim.sub',pg_temp.u(1)::text,false);
select public.decide_request((select id from public.approval_requests where organization_id=pg_temp.org() and kind='timesheet'),'approve');
