\set ON_ERROR_STOP on
-- Called after fictional p0_3_fixture; reusable in rollback and independent-session tests.
create or replace function pg_temp.expect(ok boolean,label text) returns void language plpgsql as $$ begin if ok is distinct from true then raise exception 'FAILED: %',label; end if; raise notice 'ok - %',label; end $$;
create or replace function pg_temp.denied(stmt text,state text,label text) returns void language plpgsql as $$ begin execute stmt; raise exception 'no error: %',label; exception when others then if sqlstate<>state then raise exception 'FAILED: % (% %)',label,sqlstate,sqlerrm; end if; raise notice 'ok - %',label; end $$;
create or replace function pg_temp.u(i int) returns uuid language sql as $$ select ('fb000000-0000-0000-0000-00000000000'||i)::uuid $$;
select set_config('request.jwt.claim.sub',pg_temp.u(1)::text,false);
create function pg_temp.mo() returns uuid language sql as $$ select 'fb100000-0000-0000-0000-000000000088'::uuid $$;
insert into public.organizations(id,name,time_zone) values(pg_temp.mo(),'Fictional monthly payroll','Asia/Manila');
insert into public.memberships(organization_id,user_id,status) select pg_temp.mo(),pg_temp.u(i),'active' from generate_series(1,4)i;
insert into public.membership_roles(membership_id,role_id)
select m.id,r.id from public.memberships m join public.roles r on r.organization_id is null and r.key=case when m.user_id=pg_temp.u(1) then 'owner' when m.user_id=pg_temp.u(4) then 'payroll' else 'staff' end where m.organization_id=pg_temp.mo();
insert into app.ph_employment_history values(pg_temp.mo(),pg_temp.u(2),'2025-01-01','2025-01-01Z','employed','monthly',30000,'site','wage','fictional monthly-paid evidence',pg_temp.u(1));
select app.ph_prepare_month(pg_temp.mo(),pg_temp.u(2),'2025-01-01','2025-01-01',365,600,30308.22,30000,30000,'fictional full-month no other earnings or unpaid absence');
select pg_temp.denied($$select app.ph_review_month(pg_temp.mo(),pg_temp.u(2),'2025-01-01','self review')$$,'42501','month maker cannot approve');
select set_config('request.jwt.claim.sub',pg_temp.u(4)::text,true);
select app.ph_review_month(pg_temp.mo(),pg_temp.u(2),'2025-01-01','fictional CPA review');
select pg_temp.denied($$select app.ph_post_month(pg_temp.mo(),pg_temp.u(2),'2025-01-01')$$,'P0001','missing locked evidence blocks posting');
-- Synthetic sealed-source rows for isolated monetary integration only.
-- Attendance reconciliation itself is exercised by the canonical PR12 fixtures.
select set_config('request.jwt.claim.sub',pg_temp.u(1)::text,true);
do $$ declare w date;d date;t uuid;j jsonb; begin
for w in select '2024-12-30'::date+i*7 from generate_series(0,4)i loop
 insert into app.accounting_period_manifest values(pg_temp.mo(),w,'Asia/Manila','fictional monthly roster',pg_temp.u(1),false);
 for d in select w+i from generate_series(0,6)i where w+i between date '2025-01-01' and date '2025-01-31' loop
  insert into app.accounting_roster_day values(pg_temp.mo(),w,pg_temp.u(2),d,480,0,'fictional policy');
  perform app.ph_record_workday(pg_temp.mo(),w,pg_temp.u(2),d,(d+time '08:00') at time zone 'Asia/Manila',jsonb_build_object(d::text,'ordinary',(d+1)::text,'ordinary'),'fictional workday');
 end loop;
 update app.accounting_period_manifest set sealed=true where organization_id=pg_temp.mo() and period_start=w;
 insert into public.timesheets(organization_id,user_id,period_start,status) values(pg_temp.mo(),pg_temp.u(2),w,'locked') returning id into t;
 j:=jsonb_build_object('classificationVersion',4,'exactOvertimeReviewSeconds',0,'payLines',case when w=date '2025-01-06' then
 jsonb_build_array(jsonb_build_object('workday','2025-01-06','date','2025-01-06','seconds',7200,'multiplier',1.25,'code','REG_OT')) else '[]'::jsonb end);
 insert into app.accounting_submission values(pg_temp.mo(),w,pg_temp.u(2),j,t);
 insert into app.accounting_locked_snapshot values(pg_temp.mo(),w,pg_temp.u(2),j);
 insert into public.payroll_periods(organization_id,period_start,locked_by) values(pg_temp.mo(),w,pg_temp.u(1));
end loop; end $$;
