\set ON_ERROR_STOP on
begin;
set local lock_timeout='15s';
set local statement_timeout='30s';
select set_config('request.jwt.claim.sub','fb000000-0000-0000-0000-000000000001',true);
select app.ph_post_benefit('fb100000-0000-0000-0000-000000000001','fb000000-0000-0000-0000-000000000002',:'benefit_key','2026-01-06','rice',2000,null,null,'fictional concurrent receipt');
select pg_sleep(1);
commit;
