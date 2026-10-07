-- One platform-wide boot video for every wall display. No row means each Pi
-- plays the clip installed with the app. The file lives in the private
-- `boot-video` bucket at current.mp4. Apply this migration (supabase db push),
-- then redeploy the admin edge function so Settings → Boot video can upload.
--
-- The Pi downloads that object with the anon (or publishable) key in
-- /etc/homeos/display.env. It has no user session and cannot use the service
-- role key, so anon (and a paired display) may read that one object, and
-- nothing else here. The row is for the admin function, which uses the
-- service role: it names the admin who set the video. Pending uploads stay
-- invisible.
--
-- Safe to run again (an earlier copy may have been pasted into the SQL
-- editor). A re-run also takes back the anon read grant that copy gave.

create table if not exists public.platform_boot_video (
  id          boolean primary key default true check (id),
  byte_size   bigint not null check (byte_size > 0 and byte_size <= 20971520),
  duration_ms integer not null check (duration_ms >= 500 and duration_ms <= 12000),
  updated_at  timestamptz not null default now(),
  updated_by  uuid
);

alter table public.platform_boot_video enable row level security;

revoke all on table public.platform_boot_video from public, anon, authenticated;
grant select, insert, update, delete on table public.platform_boot_video to service_role;

drop policy if exists platform_boot_video_read on public.platform_boot_video;

-- Storage exists on hosted Supabase and in the storage SQL test, not in the
-- plain Postgres run.
do $boot$
begin
  if to_regclass('storage.buckets') is null then
    return;
  end if;

  insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
  values ('boot-video', 'boot-video', false, 20971520, array['video/mp4'])
  on conflict (id) do update
    set public = false,
        file_size_limit = excluded.file_size_limit,
        allowed_mime_types = excluded.allowed_mime_types;

  drop policy if exists "boot video read" on storage.objects;
  create policy "boot video read" on storage.objects
    for select to anon, authenticated
    using (bucket_id = 'boot-video' and name = 'current.mp4');
end
$boot$;
