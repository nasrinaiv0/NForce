\set ON_ERROR_STOP on
begin;
set local lock_timeout='15s';
set local statement_timeout='30s';
select set_config('request.jwt.claim.sub','fb000000-0000-0000-0000-000000000004',true);
do $$ declare j jsonb; begin
j:=app.ph_post_month('fb100000-0000-0000-0000-000000000088','fb000000-0000-0000-0000-000000000002','2025-01-01');
if (j->>'net')::numeric<>26783.19 then raise exception 'monetary post result mismatch'; end if;
raise notice 'PH_MONEY_POST_OK';
end $$;
select pg_sleep(1);
commit;
