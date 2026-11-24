\set ON_ERROR_STOP on
begin;
set local lock_timeout='15s';
set local statement_timeout='30s';
select set_config('request.jwt.claim.sub','fb000000-0000-0000-0000-000000000004',true);
select app.ph_approve_reversal('fb100000-0000-0000-0000-000000000088','fb000000-0000-0000-0000-000000000002','2025-01-01','independent race review');
select pg_sleep(1);
commit;
