\set ON_ERROR_STOP on
begin;
set local statement_timeout='3s';
select app.accounting_tenant_lock('fc100000-0000-0000-0000-000000000002');
do $$
begin
  if pg_try_advisory_xact_lock(hashtextextended('nforce-accounting-v4:fb100000-0000-0000-0000-000000000001',0)) then raise exception 'tenant A lock not held'; end if;
  begin
    update public.memberships set job_title='blocked write' where organization_id='fb100000-0000-0000-0000-000000000001';
    raise exception 'same-tenant write not rejected';
  exception when serialization_failure then
    raise notice 'ok - same-tenant writer retries; unrelated tenant acquired lock';
  end;
  begin
    delete from public.membership_roles where membership_id in (select id from public.memberships where organization_id='fb100000-0000-0000-0000-000000000001');
    raise exception 'same-tenant role change not rejected';
  exception when serialization_failure then
    raise notice 'ok - authorization role mutation waits for accounting transaction via retry';
  end;
end $$;
rollback;
