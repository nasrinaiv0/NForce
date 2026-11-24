\set ON_ERROR_STOP on
do $$ declare o uuid:='fc900000-0000-0000-0000-000000000027';begin
 if (select count(*) from app.ph_statutory_journal where organization_id=o and category='maternity_contribution' and debit_total=22175 and credit_total=22175)<>1
 or (select count(*) from app.ph_statutory_journal where organization_id=o and category='maternity_contribution')<>1
 or (select count(*) from public.audit_events where organization_id=o and action='accounting.ph_maternity_contributions')<>1
 then raise exception 'maternity allocation not exactly once';end if;
 raise notice 'ok - two independent maternity contribution connections, one balanced journal and one audit';
end $$;
