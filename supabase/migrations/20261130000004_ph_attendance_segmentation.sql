-- Private pure candidate; inputs must be independently attested compensable work.
-- Workday anchor is explicit (not midnight); holiday/rest classifications are calendar-date evidence.
create function app.ph_segment_workday(p_anchor timestamptz,p_intervals tstzrange[],p_days jsonb)
returns table(start_at timestamptz,end_at timestamptz,local_day date,day_kind text,night_shift boolean,overtime boolean,worked_seconds numeric)
language plpgsql stable set search_path='' as $$
declare r tstzrange; cursor_at timestamptz; stop_at timestamptz; prev_end timestamptz;
  local_at timestamp; boundary timestamptz; used numeric:=0; span_seconds numeric;
begin
  if p_anchor is null or not isfinite(p_anchor) or p_intervals is null or cardinality(p_intervals)>128
    or p_days is null or jsonb_typeof(p_days)<>'object' then raise exception 'invalid workday inputs' using errcode='22023'; end if;
  for r in select v from unnest(p_intervals) v order by lower(v) loop
    if r is null or isempty(r) or lower_inf(r) or upper_inf(r) or not lower_inc(r) or upper_inc(r)
      or not isfinite(lower(r)) or not isfinite(upper(r)) or lower(r)<p_anchor
      or upper(r)>p_anchor+interval '24 hours' or (prev_end is not null and lower(r)<prev_end)
    then raise exception 'invalid or overlapping compensable interval' using errcode='22023'; end if;
    prev_end:=upper(r); cursor_at:=lower(r);
    while cursor_at<upper(r) loop
      local_at:=cursor_at at time zone 'Asia/Manila'; local_day:=local_at::date;
      day_kind:=p_days->>local_day::text;
      if day_kind is null or day_kind not in ('ordinary','rest','special','special_rest','regular_holiday','regular_holiday_rest','double_regular','double_regular_rest') then
        raise exception 'missing or unsupported local day classification' using errcode='22023';
      end if;
      night_shift:=local_at::time<time '06:00' or local_at::time>=time '22:00';
      overtime:=used>=28800;
      boundary:=(case when local_at::time<time '06:00' then local_day+time '06:00'
        when local_at::time<time '22:00' then local_day+time '22:00'
        else (local_day+1)::timestamp end) at time zone 'Asia/Manila';
      stop_at:=least(upper(r),boundary);
      if not overtime then stop_at:=least(stop_at,cursor_at+(28800-used)*interval '1 second'); end if;
      span_seconds:=extract(epoch from stop_at-cursor_at);
      if span_seconds<=0 then raise exception 'invalid segmentation progress' using errcode='22023'; end if;
      start_at:=cursor_at; end_at:=stop_at; worked_seconds:=span_seconds;
      return next;
      used:=used+span_seconds; cursor_at:=stop_at;
    end loop;
  end loop;
end $$;
revoke all on function app.ph_segment_workday(timestamptz,tstzrange[],jsonb) from public,anon,authenticated,service_role;
