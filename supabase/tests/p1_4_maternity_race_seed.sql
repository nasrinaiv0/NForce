\set ON_ERROR_STOP on
begin;

-- Fictional committed fixture when invoked by the multi-session runner.
create function pg_temp.expect(ok boolean,label text) returns void language plpgsql as $$
begin if ok is distinct from true then raise exception 'FAILED: %',label; end if; raise notice 'ok - %',label; end $$;
create function pg_temp.denied(stmt text,state text,label text) returns void language plpgsql as $$
begin execute stmt; raise exception 'no error: %',label;
exception when others then if sqlstate<>state then raise exception 'FAILED: % (% %)',label,sqlstate,sqlerrm; end if; raise notice 'ok - %',label; end $$;
create function pg_temp.org() returns uuid language sql as $$ select 'fb100000-0000-0000-0000-000000000001'::uuid $$;
create function pg_temp.u(i int) returns uuid language sql as $$ select ('fb000000-0000-0000-0000-00000000000'||i)::uuid $$;
\ir p1_2_cutoff_fixture.sql
\ir p1_4_maternity_integration_fixture.sql
commit;
