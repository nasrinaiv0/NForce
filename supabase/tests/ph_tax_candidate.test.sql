\set ON_ERROR_STOP on
begin;
create function pg_temp.assert_tax(ok boolean,label text) returns void language plpgsql as $$
begin if ok is distinct from true then raise exception 'FAILED: %',label; end if; end $$;
create function pg_temp.invalid_tax(a numeric,f text,d date) returns void language plpgsql as $$
begin
  perform app.ph_tax_candidate(a,f,d);
  raise exception 'invalid input accepted';
exception when sqlstate '22023' then null;
end $$;
-- 96 literal expected boundary values, cross-checked with Python Decimal.
do $$
declare r record; n integer:=0;
begin
  for r in select * from (values
('daily',684.99,0.00),
('daily',685.00,0.00),
('daily',685.01,0.00),
('daily',686.00,0.15),
('daily',1095.99,61.65),
('daily',1096.00,61.65),
('daily',1096.01,61.65),
('daily',1097.00,61.85),
('daily',2191.99,280.85),
('daily',2192.00,280.85),
('daily',2192.01,280.85),
('daily',2193.00,281.10),
('daily',5478.99,1102.60),
('daily',5479.00,1102.60),
('daily',5479.01,1102.60),
('daily',5480.00,1102.90),
('weekly',4807.99,0.00),
('weekly',4808.00,0.00),
('weekly',4808.01,0.00),
('weekly',4809.00,0.15),
('weekly',7691.99,432.60),
('weekly',7692.00,432.60),
('weekly',7692.01,432.60),
('weekly',7693.00,432.80),
('weekly',15384.99,1971.20),
('weekly',15385.00,1971.20),
('weekly',15385.01,1971.20),
('weekly',15386.00,1971.45),
('weekly',38461.99,7740.45),
('weekly',38462.00,7740.45),
('weekly',38462.01,7740.45),
('weekly',38463.00,7740.75),
('weekly',153845.99,42355.65),
('weekly',153846.00,42355.65),
('weekly',153846.01,42355.65),
('weekly',153847.00,42356.00),
('semi-monthly',10416.99,0.00),
('semi-monthly',10417.00,0.00),
('semi-monthly',10417.01,0.00),
('semi-monthly',10418.00,0.15),
('semi-monthly',16666.99,937.50),
('semi-monthly',16667.00,937.50),
('semi-monthly',16667.01,937.50),
('semi-monthly',16668.00,937.70),
('semi-monthly',33332.99,4270.70),
('semi-monthly',33333.00,4270.70),
('semi-monthly',33333.01,4270.70),
('semi-monthly',33334.00,4270.95),
('semi-monthly',83332.99,16770.70),
('semi-monthly',83333.00,16770.70),
('semi-monthly',83333.01,16770.70),
('semi-monthly',83334.00,16771.00),
('semi-monthly',333332.99,91770.70),
('semi-monthly',333333.00,91770.70),
('semi-monthly',333333.01,91770.70),
('semi-monthly',333334.00,91771.05),
('monthly',20832.99,0.00),
('monthly',20833.00,0.00),
('monthly',20833.01,0.00),
('monthly',20834.00,0.15),
('monthly',33332.99,1875.00),
('monthly',33333.00,1875.00),
('monthly',33333.01,1875.00),
('monthly',33334.00,1875.20),
('monthly',66666.99,8541.80),
('monthly',66667.00,8541.80),
('monthly',66667.01,8541.80),
('monthly',66668.00,8542.05),
('monthly',166666.99,33541.80),
('monthly',166667.00,33541.80),
('monthly',166667.01,33541.80),
('monthly',166668.00,33542.10),
('monthly',666666.99,183541.80),
('monthly',666667.00,183541.80),
('monthly',666667.01,183541.80),
('monthly',666668.00,183542.15),
('annual',249999.99,0.00),
('annual',250000.00,0.00),
('annual',250000.01,0.00),
('annual',250001.00,0.15),
('annual',399999.99,22500.00),
('annual',400000.00,22500.00),
('annual',400000.01,22500.00),
('annual',400001.00,22500.20),
('annual',799999.99,102500.00),
('annual',800000.00,102500.00),
('annual',800000.01,102500.00),
('annual',800001.00,102500.25),
('annual',1999999.99,402500.00),
('annual',2000000.00,402500.00),
('annual',2000000.01,402500.00),
('annual',2000001.00,402500.30),
('annual',7999999.99,2202500.00),
('annual',8000000.00,2202500.00),
('annual',8000000.01,2202500.00),
('annual',8000001.00,2202500.35)
  ) as v(freq,amount,expected) loop
    perform pg_temp.assert_tax(app.ph_tax_candidate(r.amount,r.freq,date '2026-11-24')=r.expected,
      r.freq||' '||r.amount::text);
    n:=n+1;
  end loop;
  raise notice '% boundary fixtures passed',n;
end $$;
select pg_temp.assert_tax(app.ph_tax_candidate(27550,'monthly','2026-11-24')=1007.55,'monthly reference');
select pg_temp.assert_tax(app.ph_tax_candidate(500000,'annual','2026-11-24')=42500,'annual reference');
select pg_temp.assert_tax(app.ph_tax_candidate(22000,'semi-monthly','2026-11-24')=2004.10,'semi-monthly reference');
select pg_temp.assert_tax(app.ph_tax_candidate(20833.10,'monthly','2026-11-24')=0.02,'half-up cents');
select pg_temp.assert_tax(app.ph_tax_candidate(0,'monthly','2023-01-01')=0,'first supported date');
select pg_temp.invalid_tax(21918,'daily','2026-11-24');
select pg_temp.invalid_tax(-1,'monthly','2026-11-24');
select pg_temp.invalid_tax('NaN','monthly','2026-11-24');
select pg_temp.invalid_tax('Infinity','monthly','2026-11-24');
select pg_temp.invalid_tax('-Infinity','monthly','2026-11-24');
select pg_temp.invalid_tax(1.001,'monthly','2026-11-24');
select pg_temp.invalid_tax(1000000001,'monthly','2026-11-24');
select pg_temp.invalid_tax(null,'monthly','2026-11-24');
select pg_temp.invalid_tax(1,null,'2026-11-24');
select pg_temp.invalid_tax(1,'biweekly','2026-11-24');
select pg_temp.invalid_tax(1,'monthly',null);
select pg_temp.invalid_tax(1,'monthly','2022-12-31');
select pg_temp.invalid_tax(1,'monthly','2026-11-25');
do $$
declare r text;
begin
  foreach r in array array['anon','authenticated','service_role'] loop
    perform pg_temp.assert_tax(not has_function_privilege(r,'app.ph_tax_candidate(numeric,text,date)','EXECUTE'),'private function: '||r);
  end loop;
  raise notice 'PH tax reference, input guard and API grant checks passed';
end $$;
rollback;
