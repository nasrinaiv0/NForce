\set ON_ERROR_STOP on
begin;
\ir p0_3_fixture.sql
do $$
declare n int;
begin
 select count(*) into n from (select r,s,f from unnest(array[0,0.01,63.75,75,123.456789,1000000000]::numeric[]) r
 cross join unnest(array[0,1,59,60,3599,3600,28800,86400]::numeric[]) s
 cross join unnest(array[0,0.1,0.25,1,1.1,1.25,1.375,1.69,2,3.9,5.577]::numeric[]) f
 where app.ph_exact_line_amount(r,s,f)::text is distinct from (r*s/3600*f)::text) x;
 perform pg_temp.expect(n=0,'528 exact PostgreSQL line amount and scale comparisons');
 select count(*) into n from (select g,e,d from unnest(array[0,0.01,540,1211.25,30000,1000000000]::numeric[]) g
 cross join unnest(array[0,0.01,200,2500,90000]::numeric[]) e
 cross join unnest(array[0,0.01,600,2450,5000]::numeric[]) d
 where app.ph_exact_taxable(g,e,d)::text is distinct from (g-e-d)::text) x;
 perform pg_temp.expect(n=0,'150 exact taxable comparisons including unchanged negative intermediates');
 perform pg_temp.expect(app.ph_exact_line_amount(null,1,1) is null and app.ph_exact_taxable(1,null,0) is null,'null propagation unchanged');
 foreach n in array array[1,2,3] loop
 perform pg_temp.expect(not has_function_privilege((array['anon','authenticated','service_role'])[n],'app.ph_exact_line_amount(numeric,numeric,numeric)','EXECUTE'),'line helper private');
 perform pg_temp.expect(not has_function_privilege((array['anon','authenticated','service_role'])[n],'app.ph_exact_taxable(numeric,numeric,numeric)','EXECUTE'),'taxable helper private');
 end loop;
end $$;
rollback;
