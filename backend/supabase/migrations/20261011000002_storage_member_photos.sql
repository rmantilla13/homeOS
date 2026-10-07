-- Supabase-specific: member photos in the `avatars` bucket, at
-- '<family_id>/<file>' (see 20261011000001). The family's parents upload,
-- replace and delete them. Reads go through can_read_avatar, like profile
-- photos ("avatars read" in 20261007000005).

create policy "member photos upload" on storage.objects for insert
  with check (bucket_id = 'avatars' and public.can_write_member_photo(name));

create policy "member photos update" on storage.objects for update
  using (bucket_id = 'avatars' and public.can_write_member_photo(name))
  with check (bucket_id = 'avatars' and public.can_write_member_photo(name));

create policy "member photos delete" on storage.objects for delete
  using (bucket_id = 'avatars' and public.can_write_member_photo(name));
