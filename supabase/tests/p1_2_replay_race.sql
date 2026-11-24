\set ON_ERROR_STOP on
begin;
set local lock_timeout='15s';
set local statement_timeout='30s';
select set_config('request.jwt.claim.sub','fb000000-0000-0000-0000-000000000004',true);
do $$ declare j jsonb;begin
 j:=app.ph_replay_cutoff_2026('fc900000-0000-0000-0000-000000000011','fb000000-0000-0000-0000-000000000002','2026-09-15');
 if (j->>'net')::numeric is distinct from 4557.55::numeric then raise exception 'race replay mismatch';end if;
 j:=app.ph_replay_cutoff_2026('fc900000-0000-0000-0000-000000000014','fb000000-0000-0000-0000-000000000002','2026-02-01');
 if (j->>'net')::numeric is distinct from 27392.45::numeric then raise exception 'monthly race replay mismatch';end if;
 raise notice 'P12_REPLAY_OK';
 perform pg_sleep(1);
end $$;
commit;
