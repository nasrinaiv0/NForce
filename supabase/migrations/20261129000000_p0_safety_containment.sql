-- Conservative release gate pending authoritative historical payroll reconciliation.
-- Keep existing records and schema; deny unsafe live writes rather than estimate pay.
revoke execute on function public.submit_timesheet(uuid, date, integer, integer) from public, anon, authenticated;
revoke execute on function public.lock_payroll_period(uuid, date) from public, anon, authenticated;

-- The general request endpoint must not bypass the accounting release gate.
create function app.block_unverified_timesheet_request() returns trigger
language plpgsql set search_path = '' as $$
begin
  if new.kind = 'timesheet' then
    raise exception 'Timesheet accounting is not enabled for live workspaces' using errcode = '42501';
  end if;
  return new;
end $$;
revoke all on function app.block_unverified_timesheet_request() from public, anon, authenticated;
create trigger p0_timesheet_request_gate before insert on public.approval_requests
for each row execute function app.block_unverified_timesheet_request();

-- Hosted projects may contain the platform-installed DDL event trigger; the
-- local PostgreSQL test shim does not. Preserve trigger and function definition.
do $$
begin
  if to_regprocedure('public.rls_auto_enable()') is not null then
    execute 'revoke execute on function public.rls_auto_enable() from public, anon, authenticated';
  end if;
end $$;
