\set ON_ERROR_STOP on
begin;
select app.accounting_tenant_lock('fb100000-0000-0000-0000-000000000001');
\echo P04_LOCK_HELD
select pg_sleep(5);
rollback;
