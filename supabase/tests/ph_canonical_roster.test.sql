\set ON_ERROR_STOP on
begin;
\ir p0_3_fixture.sql
-- 32 published minimum rate combinations, exact numeric, not floating point.
do $$ declare r record; n int:=0; begin
 for r in select * from (values
 ('ordinary',1,1.25,1.10,1.375),
 ('rest',1.3,1.69,1.43,1.859),
 ('special',1.3,1.69,1.43,1.859),
 ('special_rest',1.5,1.95,1.65,2.145),
 ('regular_holiday',2,2.6,2.2,2.86),
 ('regular_holiday_rest',2.6,3.38,2.86,3.718),
 ('double_regular',3,3.9,3.3,4.29),
 ('double_regular_rest',3.9,5.07,4.29,5.577)
 ) v(kind,base,ot,nd,both) loop
 perform pg_temp.expect(app.ph_premium_factor(r.kind,false,false)=r.base,r.kind||' ordinary');
 perform pg_temp.expect(app.ph_premium_factor(r.kind,true,false)=r.ot,r.kind||' OT');
 perform pg_temp.expect(app.ph_premium_factor(r.kind,false,true)=r.nd,r.kind||' ND');
 perform pg_temp.expect(app.ph_premium_factor(r.kind,true,true)=r.both,r.kind||' OT+ND');
 n:=n+4;
 end loop; raise notice '% exact premium factor cases passed',n;
end $$;
-- Rehire from canonical history; no second eligibility row.
insert into app.ph_employment_history values(pg_temp.org(),pg_temp.u(2),'2025-01-13','2025-01-13Z','employed','daily',650,'site','wage','fixture rehire',pg_temp.u(1));
select pg_temp.denied($$select app.ph_materialize_week(pg_temp.org(),'2025-01-13','fixture missing shift')$$,'P0001','no implicit shift fallback');
select app.ph_record_shift(pg_temp.org(),pg_temp.u(2),'2025-01-13','08:00','17:00',array[6,7]::smallint[],'fixture shift');
select app.ph_record_site_calendar(pg_temp.org(),'site','2025-01-13'::date+i,'ordinary','fixture calendar') from generate_series(0,6)i;
select pg_temp.denied($$select app.ph_materialize_week(pg_temp.org(),'2025-01-13','fixture missing next date')$$,'P0001','missing next-date calendar rejected');
select pg_temp.expect((select count(*)=0 from app.accounting_period_manifest where period_start='2025-01-13'),'failed materialization atomic');
select app.ph_record_site_calendar(pg_temp.org(),'site','2025-01-20','ordinary','next date evidence');
select app.ph_record_site_calendar(pg_temp.org(),'site','2025-01-18','regular_holiday','fictional amended holiday');
select app.ph_materialize_week(pg_temp.org(),'2025-01-13','fictional canonical roster');
select pg_temp.expect((select count(*)=7 from app.accounting_roster_day where period_start='2025-01-13'),'seven eligible dates only');
select pg_temp.expect((select count(*)=7 from app.ph_workday_sources where period_start='2025-01-13'),'all exact shift and calendar sources linked');
select pg_temp.expect((select sealed from app.accounting_period_manifest where period_start='2025-01-13'),'manifest sealed');
select pg_temp.expect((select calendar_classes->>'2025-01-18'='regular_holiday_rest' from app.ph_workday_evidence where work_date='2025-01-18'),'rest and holiday revision selected');
select app.ph_record_site_calendar(pg_temp.org(),'site','2025-01-18','ordinary','later fictional revision');
select pg_temp.expect((select calendar_classes->>'2025-01-18'='regular_holiday_rest' from app.ph_workday_evidence where work_date='2025-01-18'),'later revision cannot change sealed evidence');
select pg_temp.denied($$update app.ph_workday_sources set site_reference='tamper'$$,'42501','source links immutable');
-- Distinct tenant, actor has no membership there.
insert into public.organizations(id,name,time_zone) values('fb100000-0000-0000-0000-000000000099','Fictional other tenant','Asia/Manila');
insert into public.memberships(organization_id,user_id,status) values('fb100000-0000-0000-0000-000000000099',pg_temp.u(2),'active');
select pg_temp.denied($$select app.ph_record_site_calendar('fb100000-0000-0000-0000-000000000099','site','2025-01-13','ordinary','unauthorized')$$,'42501','cross-tenant calendar denied');
select pg_temp.denied($$select app.ph_materialize_week('fb100000-0000-0000-0000-000000000099','2025-01-13','unauthorized')$$,'42501','cross-tenant roster denied');
select pg_temp.denied($$select app.ph_open_benefit_year('fb100000-0000-0000-0000-000000000099',pg_temp.u(2),'2026-01-05','{}',0,'monthly','unauthorized')$$,'42501','cross-tenant benefit denied');
select pg_temp.denied($$select app.ph_annual_from_verified_2316('fb100000-0000-0000-0000-000000000099',pg_temp.u(2),'2026-11-24','2026-12-15','year_end',100,0,0,'2026-01-01','unauthorized')$$,'42501','cross-tenant annualization denied');
do $$ declare r text; t text; begin
foreach r in array array['anon','authenticated','service_role'] loop
 foreach t in array array['ph_shift_history','ph_site_calendar_history','ph_workday_sources'] loop
 perform pg_temp.expect(not has_table_privilege(r,'app.'||t,'SELECT,INSERT,UPDATE,DELETE'),'private roster table '||r||' '||t);
 end loop;
 perform pg_temp.expect(not has_function_privilege(r,'app.ph_materialize_week(uuid,date,text)','EXECUTE'),'private roster materializer');
end loop; end $$;
rollback;
