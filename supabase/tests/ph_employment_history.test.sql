\set ON_ERROR_STOP on
begin;
create function pg_temp.ok(b boolean,l text) returns void language plpgsql as $$ begin if b is distinct from true then raise exception 'FAIL %',l; end if; end $$;
create function pg_temp.reject(q text,s text) returns void language plpgsql as $$ begin execute q; raise exception 'unexpected success'; exception when others then if sqlstate<>s then raise; end if; end $$;
create function pg_temp.o(i int) returns uuid language sql as $$ select ('fd100000-0000-0000-0000-00000000000'||i)::uuid $$;
create function pg_temp.u(i int) returns uuid language sql as $$ select ('fd200000-0000-0000-0000-00000000000'||i)::uuid $$;
insert into auth.users(id) values(pg_temp.u(1)),(pg_temp.u(2));
insert into public.organizations(id,name,time_zone) values(pg_temp.o(1),'Fictional A','Asia/Manila'),(pg_temp.o(2),'Fictional B','Asia/Manila');
insert into public.memberships(organization_id,user_id,status) values(pg_temp.o(1),pg_temp.u(1),'active'),(pg_temp.o(2),pg_temp.u(1),'active');
insert into app.ph_employment_history values
(pg_temp.o(1),pg_temp.u(1),'2025-01-01','2025-01-01Z','employed','daily',600,'site-a','wage-a','hire',pg_temp.u(2)),
(pg_temp.o(1),pg_temp.u(1),'2025-06-01','2025-06-01Z','employed','daily',650,'site-a','wage-b','raise',pg_temp.u(2)),
(pg_temp.o(1),pg_temp.u(1),'2025-06-01','2025-07-01Z','employed','daily',660,'site-a','wage-b','correction',pg_temp.u(2)),
(pg_temp.o(1),pg_temp.u(1),'2025-08-01','2025-08-01Z','separated',null,null,null,null,'separation',pg_temp.u(2)),
(pg_temp.o(1),pg_temp.u(1),'2025-10-01','2025-10-01Z','employed','monthly',20000,'site-b','wage-c','rehire',pg_temp.u(2)),
(pg_temp.o(2),pg_temp.u(1),'2025-01-01','2025-01-01Z','employed','daily',900,'site-c','wage-d','hire',pg_temp.u(2));
select pg_temp.ok((app.ph_employment_as_of(pg_temp.o(1),pg_temp.u(1),'2025-05-31','2025-12-01Z')).rate_php=600,'historical salary');
select pg_temp.ok((app.ph_employment_as_of(pg_temp.o(1),pg_temp.u(1),'2025-06-01','2025-06-30Z')).rate_php=650,'prior knowledge cutoff');
select pg_temp.ok((app.ph_employment_as_of(pg_temp.o(1),pg_temp.u(1),'2025-06-01','2025-07-02Z')).rate_php=660,'correction');
select pg_temp.ok((app.ph_employment_as_of(pg_temp.o(1),pg_temp.u(1),'2025-08-01','2025-12-01Z')).status='separated','separation');
select pg_temp.ok((app.ph_employment_as_of(pg_temp.o(1),pg_temp.u(1),'2025-10-01','2025-12-01Z')).rate_php=20000,'rehire');
select pg_temp.ok((app.ph_employment_as_of(pg_temp.o(2),pg_temp.u(1),'2025-05-31','2025-12-01Z')).rate_php=900,'tenant scope');
select pg_temp.reject($$select app.ph_employment_as_of(pg_temp.o(1),pg_temp.u(1),'2024-12-31','2025-12-01Z')$$,'P0001');
select pg_temp.reject($$update app.ph_employment_history set rate_php=1$$,'42501');
select pg_temp.reject($$delete from app.ph_employment_history$$,'42501');
select pg_temp.reject($$insert into app.ph_employment_history values(pg_temp.o(1),pg_temp.u(1),'2025-11-01','2025-11-01Z','employed','daily',null,'site','wage','bad',pg_temp.u(2))$$,'23514');
do $$ declare r text; begin foreach r in array array['anon','authenticated','service_role'] loop
perform pg_temp.ok(not has_table_privilege(r,'app.ph_employment_history','SELECT,INSERT,UPDATE,DELETE'),'table private');
perform pg_temp.ok(not has_function_privilege(r,'app.ph_employment_as_of(uuid,uuid,date,timestamptz)','EXECUTE'),'function private');
end loop; raise notice 'PH employment history lifecycle, immutability and role tests passed'; end $$;
rollback;
