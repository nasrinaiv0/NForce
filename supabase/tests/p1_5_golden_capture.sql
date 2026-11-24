-- Test-only snapshot: omit random identifiers/timestamps, retain exact numeric
-- values, contribution breakdown, per-line amounts, journals and revisions.
select 'P15_GOLDEN|'||jsonb_build_object(
 'snapshots',coalesce((select jsonb_agg(jsonb_build_object(
 'org',s.organization_id,'user',s.user_id,'start',s.period_start,'payDate',s.pay_date,'frequency',s.frequency,'revision',s.revision,
 'gross',s.gross,'exempt',s.exempt,'ee',s.employee_contributions,'er',s.employer_contributions,'taxable',s.taxable,'taxDeductible',s.tax_deductible,'tax',s.withholding,'net',s.net,
 'contributions',s.evidence->'contributions','basic',s.evidence->'basic','premium',s.evidence->'premium','cumulative',s.evidence->'cumulative',
 'weeklyLineAmounts',(select jsonb_agg(x->'unroundedAmount' order by ord) from jsonb_array_elements(coalesce(s.evidence->'earnings','[]'::jsonb)) with ordinality as e(x,ord)),
 'journal',j.lines,'debit',j.debit_total,'credit',j.credit_total)
 order by s.organization_id,s.user_id,s.period_start,s.revision)
 from app.ph_monetary_snapshot s join app.ph_payroll_journal j using(organization_id,user_id,period_start,revision)),'[]'::jsonb),
 'reversals',coalesce((select jsonb_agg(jsonb_build_object('org',organization_id,'user',user_id,'period',period_start,'lines',lines,'debit',debit_total,'credit',credit_total) order by organization_id,user_id,period_start) from app.ph_canonical_reversal),'[]'::jsonb),
 'effective',coalesce((select jsonb_agg(jsonb_build_array(organization_id,user_id,period_start,revision) order by organization_id,user_id,period_start) from app.ph_effective_monetary),'[]'::jsonb),
 'annual',coalesce((select jsonb_agg(jsonb_build_object('org',organization_id,'user',user_id,'period',final_period,'revision',final_revision,'refund',result->'refund','employeeWithholding',result->'employeeWithholding','employerAdvance',result->'employerAdvance') order by organization_id,user_id,tax_year) from app.ph_annual_settlement),'[]'::jsonb)
)::text;
