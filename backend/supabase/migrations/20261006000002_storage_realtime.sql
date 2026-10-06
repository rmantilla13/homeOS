-- Supabase-specific setup: media storage bucket and realtime publication.

insert into storage.buckets (id, name, public)
values ('family-media', 'family-media', false)
on conflict (id) do nothing;

-- Objects live at '<family_id>/<file>'; access follows family membership.
create policy "family media read" on storage.objects for select
  using (bucket_id = 'family-media'
         and (storage.foldername(name))[1] in (select public.my_family_ids()::text));

create policy "family media upload" on storage.objects for insert
  with check (bucket_id = 'family-media'
              and (storage.foldername(name))[1] in (select public.my_family_ids()::text));

create policy "family media delete" on storage.objects for delete
  using (bucket_id = 'family-media'
         and (storage.foldername(name))[1] in (select public.my_family_ids()::text));

-- Tables the wall display and phones subscribe to for live updates.
alter publication supabase_realtime add table
  public.events,
  public.event_members,
  public.tasks,
  public.task_completions,
  public.rewards,
  public.reward_redemptions,
  public.points_ledger,
  public.lists,
  public.list_items,
  public.meal_plans,
  public.media_items;
