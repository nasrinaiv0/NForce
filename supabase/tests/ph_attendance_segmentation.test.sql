\set ON_ERROR_STOP on
begin;
create function pg_temp.ok(b boolean,l text) returns void language plpgsql as $$ begin if b is distinct from true then raise exception 'FAIL %',l; end if; end $$;
create function pg_temp.reject(q text) returns void language plpgsql as $$ begin execute q; raise exception 'unexpected success'; exception when sqlstate '22023' then null; end $$;
create temp table seg as select * from app.ph_segment_workday('2026-01-01 20:00+08',array[
tstzrange('2026-01-01 20:00+08','2026-01-02 00:00+08'),
tstzrange('2026-01-02 01:00+08','2026-01-02 06:00:00.125+08')], '{"2026-01-01":"regular_holiday","2026-01-02":"ordinary"}');
select pg_temp.ok(sum(worked_seconds)=32400.125,'exact seconds excluding unpaid break') from seg;
select pg_temp.ok(sum(worked_seconds) filter(where overtime)=3600.125,'OT continuous across midnight') from seg;
select pg_temp.ok(sum(worked_seconds) filter(where night_shift)=25200,'night window') from seg;
select pg_temp.ok(sum(worked_seconds) filter(where day_kind='regular_holiday')=14400,'holiday attribution') from seg;
select pg_temp.ok(count(*)=5,'all boundaries split') from seg;
select pg_temp.ok(sum(worked_seconds) filter(where overtime)=0.125,'no minimum OT threshold') from app.ph_segment_workday('2026-01-03 08:00+08',array[tstzrange('2026-01-03 08:00+08','2026-01-03 16:00:00.125+08')],'{"2026-01-03":"rest"}');
select pg_temp.reject($$select * from app.ph_segment_workday('2026-01-03 08:00+08',array[tstzrange('2026-01-03 08:00+08','2026-01-03 12:00+08'),tstzrange('2026-01-03 11:00+08','2026-01-03 13:00+08')],'{"2026-01-03":"ordinary"}')$$);
select pg_temp.reject($$select * from app.ph_segment_workday('2026-01-03 08:00+08',array[tstzrange('2026-01-03 08:00+08','2026-01-03 12:00+08')],'{}')$$);
select pg_temp.reject($$select * from app.ph_segment_workday('2026-01-03 08:00+08',array[tstzrange('2026-01-03 07:00+08','2026-01-03 12:00+08')],'{"2026-01-03":"ordinary"}')$$);
do $$ declare r text; begin foreach r in array array['anon','authenticated','service_role'] loop
perform pg_temp.ok(not has_function_privilege(r,'app.ph_segment_workday(timestamptz,tstzrange[],jsonb)','EXECUTE'),'private');
end loop; raise notice 'PH exact segmentation and private grants passed'; end $$;
rollback;
