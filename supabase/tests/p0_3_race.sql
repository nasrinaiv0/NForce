
-- Run in an independent psql connection; exactly one session may lock.
\set ON_ERROR_STOP on
begin;
set local lock_timeout='15s';
set local statement_timeout='30s';
select set_config('request.jwt.claim.sub','fb000000-0000-0000-0000-000000000001',true);
do $$
begin
  perform app.accounting_lock('fb100000-0000-0000-0000-000000000001','2025-01-06');
  raise notice 'P03_RACE_WIN';
  perform pg_sleep(2);
exception when sqlstate 'P0001' then
  if sqlerrm<>'period already locked' then raise; end if;
  raise notice 'P03_RACE_ALREADY_LOCKED';
end $$;
commit;
