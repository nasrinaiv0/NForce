-- Directory is not permission to read full employment records.
-- Raw membership rows and columns are restricted independently of the
-- directory RPC. All access decisions are current tenant/server permissions.
drop policy memberships_read on public.memberships;
create policy memberships_read on public.memberships for select to authenticated
 using (app.is_member(organization_id) and (
 user_id=auth.uid()
 or app.has_permission(organization_id,'people.view',user_id)
 or app.has_permission(organization_id,'attendance.view',user_id)
 or app.has_permission(organization_id,'schedule.view',user_id)
 or app.has_permission(organization_id,'admin.roles')));
revoke select on public.memberships from public,anon,authenticated;
revoke select (reports_to,location,shift_start,shift_end,rest_days) on public.memberships from public,anon,authenticated;
grant select (id,organization_id,user_id,status,department_id,created_at,job_title) on public.memberships to authenticated;

-- Preserve the existing public contract and its basic active directory.
-- Attendance and timesheet reviewers need the schedule input for scoped
-- workforce reporting. Merely having people.directory grants neither.
create or replace function public.org_directory(p_organization_id uuid)
returns table (
 user_id uuid,membership_id uuid,display_name text,job_title text,location text,status public.membership_status,
 department_id uuid,department_name text,team_id uuid,team_name text,reports_to_user uuid,role_key text,
 shift_start time,shift_end time,rest_days smallint[]
)
language sql stable security definer set search_path='' as $$
 select m.user_id,m.id,coalesce(p.display_name,'Member'),m.job_title,
 case when access.can_people or access.can_schedule then m.location else '' end,
 m.status,m.department_id,d.name,tm.team_id,t.name,
 case when access.can_people or access.can_schedule or access.can_approve then boss.user_id else null end,
 (select r.key from public.membership_roles mr join public.roles r on r.id=mr.role_id where mr.membership_id=m.id order by r.key limit 1),
 case when access.can_schedule then m.shift_start else null end,
 case when access.can_schedule then m.shift_end else null end,
 case when access.can_schedule then m.rest_days else null end
 from public.memberships m
 left join public.profiles p on p.id=m.user_id
 left join public.departments d on d.id=m.department_id
 left join lateral (select x.team_id from public.team_members x where x.membership_id=m.id order by x.team_id limit 1) tm on true
 left join public.teams t on t.id=tm.team_id
 left join public.memberships boss on boss.id=m.reports_to and boss.organization_id=m.organization_id
 cross join lateral (select
  (m.user_id=auth.uid() or app.has_permission(m.organization_id,'people.view',m.user_id)) as can_people,
  (m.user_id=auth.uid() or app.has_permission(m.organization_id,'schedule.view',m.user_id)
   or app.has_permission(m.organization_id,'attendance.view',m.user_id)
   or app.has_permission(m.organization_id,'timesheet.view',m.user_id)) as can_schedule,
  (app.has_permission(m.organization_id,'timeoff.approve',m.user_id)
   or app.has_permission(m.organization_id,'timesheet.approve',m.user_id)
   or app.has_permission(m.organization_id,'attendance.correct',m.user_id)) as can_approve
 ) access
 where auth.uid() is not null and m.organization_id=p_organization_id and app.is_member(p_organization_id)
 and (m.user_id=auth.uid() or app.has_permission(p_organization_id,'people.directory',m.user_id))
 and (m.status='active' or access.can_people or app.has_permission(p_organization_id,'admin.roles'))
$$;
revoke all on function public.org_directory(uuid) from public,anon,authenticated,service_role;
grant execute on function public.org_directory(uuid) to authenticated;
