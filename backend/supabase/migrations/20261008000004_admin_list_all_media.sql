-- A platform admin can list photos and videos across every family.
-- Thumbnails stay behind the admin edge function (sign_media). This does
-- not add a Storage policy, and the admin app still has no service role key.

create function public.admin_list_all_media(only_kind text default null, lim int default 60, off int default 0)
returns table (id uuid, family_id uuid, family_name text, kind text, storage_path text, thumbnail_path text,
               content_type text, byte_size bigint, width int, height int, duration_seconds numeric,
               caption text, taken_at timestamptz, created_at timestamptz, show_on_frame boolean,
               uploaded_by_name text)
language plpgsql stable security definer set search_path = public as $$
declare
  want text := nullif(lower(btrim(only_kind)), '');
begin
  if not public.is_platform_admin() then raise exception 'admin only'; end if;
  if want is not null and want not in ('photo', 'video') then
    raise exception 'kind must be photo or video';
  end if;
  return query
    select m.id, m.family_id, f.name, m.kind::text, m.storage_path, m.thumbnail_path, m.content_type, m.byte_size,
           m.width, m.height, m.duration_seconds, m.caption, m.taken_at, m.created_at, m.show_on_frame,
           u.display_name
    from public.media_items m
    join public.families f on f.id = m.family_id
    left join public.members u on u.id = m.uploaded_by
    where want is null or m.kind::text = want
    order by m.taken_at desc nulls last, m.created_at desc, m.id
    limit greatest(least(coalesce(lim, 60), 100), 1) offset greatest(coalesce(off, 0), 0);
end $$;

revoke execute on function public.admin_list_all_media(text, int, int) from public, anon;
grant execute on function public.admin_list_all_media(text, int, int) to authenticated;
