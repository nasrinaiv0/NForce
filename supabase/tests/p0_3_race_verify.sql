
\set ON_ERROR_STOP on
do $$
begin
  if (select count(*) from public.payroll_periods where organization_id='fb100000-0000-0000-0000-000000000001')<>1
    or (select count(*) from app.accounting_locked_snapshot where organization_id='fb100000-0000-0000-0000-000000000001')<>1
    or (select count(*) from public.audit_events where organization_id='fb100000-0000-0000-0000-000000000001' and action='payroll.locked')<>1 then
    raise exception 'P03 concurrent lock invariant violated';
  end if;
  raise notice 'ok - two independent lock transactions leave one period, snapshot and audit event';
end $$;
