\set ON_ERROR_STOP on
do $$ declare o uuid:='fc900000-0000-0000-0000-000000000020';begin
 if (select count(*) from app.ph_statutory_journal where organization_id=o and category='sss_reimbursement')<>1
 or (select count(*) from public.audit_events where organization_id=o and action='accounting.ph_statutory_journal')<>2
 or (select sum((x->>'debit')::numeric-(x->>'credit')::numeric) from app.ph_statutory_journal j cross join lateral jsonb_array_elements(j.lines)x where j.organization_id=o and x->>'account'='sss_maternity_receivable')<>40000
 then raise exception 'reimbursement not exactly once';end if;
 raise notice 'ok - two independent reimbursement connections, one receipt and PHP40000 outstanding';
end $$;
