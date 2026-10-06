-- Supabase-specific: the private `avatars` bucket for profile photos.
-- Objects live at '<user_id>/<file>' (the app uses '<user_id>/avatar.jpg').

insert into storage.buckets (id, name, public)
values ('avatars', 'avatars', false)
on conflict (id) do nothing;

-- Owners write their own folder; anyone who shares a family with the owner
-- can read (public.can_read_avatar, defined in 20261007000001).
create policy "avatars read" on storage.objects for select
  using (bucket_id = 'avatars' and public.can_read_avatar(name));

create policy "avatars upload" on storage.objects for insert
  with check (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);

create policy "avatars update" on storage.objects for update
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text)
  with check (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);

create policy "avatars delete" on storage.objects for delete
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);
