\set ON_ERROR_STOP on
begin;
set local lock_timeout='15s';
set local statement_timeout='30s';
select set_config('request.jwt.claim.sub','fb000000-0000-0000-0000-000000000004',true);
do $$ declare j jsonb;begin
 j:=app.ph_post_maternity_contributions('fc900000-0000-0000-0000-000000000027','fb000000-0000-0000-0000-000000000002','2026-06-14');
 if (j->>'journalTotal')::numeric is distinct from 22175::numeric then raise exception 'maternity retry mismatch';end if;
 raise notice 'P14_MATERNITY_OK';
 perform pg_sleep(1);
end $$;
commit;
