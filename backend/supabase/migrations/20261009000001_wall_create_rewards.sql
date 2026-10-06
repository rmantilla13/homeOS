-- Wall create flows: a paired display may add rewards. Parents still own
-- edits and deletes (archive). See docs/PLATFORM_SPEC.md §1.8 / §5.
--
-- rewards_write required is_family_parent for every write. Device accounts
-- are family members via devices, not parents, so Add reward on the panel
-- failed under RLS. Split insert (member or display) from update/delete
-- (parents only).

drop policy if exists rewards_write on public.rewards;

create policy rewards_insert on public.rewards for insert
  with check (
    public.is_family_parent(family_id)
    or exists (
      select 1
        from public.devices d
        join public.families f on f.id = d.family_id
       where d.family_id = rewards.family_id
         and d.user_id = auth.uid()
         and f.status = 'active'
    )
  );

create policy rewards_update on public.rewards for update
  using (public.is_family_parent(family_id))
  with check (public.is_family_parent(family_id));

create policy rewards_delete on public.rewards for delete
  using (public.is_family_parent(family_id));
