\set ON_ERROR_STOP on
do $$ declare o uuid:='fc900000-0000-0000-0000-000000000011';begin
 if (select count(*) from app.ph_monetary_snapshot where organization_id=o)<>2
 or (select count(*) from app.ph_payroll_journal where organization_id=o)<>2
 or (select count(*) from app.ph_canonical_reversal where organization_id=o)<>1
 or (select count(*) from app.ph_effective_monetary where organization_id=o and revision=2 and net=4557.55)<>1
 or (select count(*) from public.audit_events where organization_id=o and action='accounting.ph_cutoff_replayed')<>1
 then raise exception 'concurrent replay not exactly once';end if;
 raise notice 'ok - two independent connections, one replacement and one replay audit';
end $$;

do $$ declare o uuid:='fc900000-0000-0000-0000-000000000014';begin
 if (select count(*) from app.ph_monetary_snapshot where organization_id=o)<>2
 or (select count(*) from app.ph_payroll_journal where organization_id=o)<>2
 or (select count(*) from app.ph_canonical_reversal where organization_id=o)<>1
 or (select count(*) from app.ph_effective_monetary where organization_id=o and revision=2 and net=27392.45)<>1
 or (select count(*) from public.audit_events where organization_id=o and action='accounting.ph_cutoff_replayed')<>1
 then raise exception 'monthly concurrent replay not exactly once';end if;
 raise notice 'ok - two independent monthly replay connections, one replacement and one audit';
end $$;
