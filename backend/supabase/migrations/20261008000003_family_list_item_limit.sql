-- The family list the console uses for the media page also needs the
-- effective item cap, so a family over its item limit shows up there
-- and not only on the family page.

drop function public.admin_list_families(text, int, int);

create function public.admin_list_families(search text default null, lim int default 50, off int default 0)
returns table (id uuid, name text, status text, created_at timestamptz, member_count int, parent_count int,
               device_count int, assistant_requests_30d int, last_activity timestamptz,
               media_count int, storage_bytes bigint, storage_limit_bytes bigint, media_item_limit int)
language plpgsql stable security definer set search_path = public as $$
declare
  q text := lower(nullif(btrim(search), ''));
begin
  if not public.is_platform_admin() then raise exception 'admin only'; end if;
  return query
    select f.id, f.name, f.status, f.created_at,
           (select count(*)::int from public.members m where m.family_id = f.id),
           (select count(*)::int from public.members m where m.family_id = f.id and m.role = 'parent'),
           (select count(*)::int from public.devices d where d.family_id = f.id),
           (select count(*)::int from public.assistant_usage u
             where u.family_id = f.id and u.created_at >= now() - interval '30 days'),
           public.family_last_activity(f.id),
           (select count(*)::int from public.media_items mi where mi.family_id = f.id),
           public.family_storage_bytes(f.id),
           public.family_storage_limit(f.id),
           public.family_media_item_limit(f.id)
    from public.families f
    where q is null or strpos(lower(f.name), q) > 0 or f.id::text = q
    order by f.created_at desc, f.id
    limit greatest(least(coalesce(lim, 50), 500), 1) offset greatest(coalesce(off, 0), 0);
end $$;

revoke execute on function public.admin_list_families(text, int, int) from public, anon;
grant execute on function public.admin_list_families(text, int, int) to authenticated;
