-- Family memory for the assistant: durable facts the family tells it
-- ("Leo is allergic to peanuts", "Soccer carpool is with the Parks").
-- Every assistant request includes these alongside the family's live data.

create table public.family_memories (
  id          uuid primary key default gen_random_uuid(),
  family_id   uuid not null references public.families on delete cascade,
  content     text not null check (length(content) between 1 and 500),
  source      text not null default 'assistant',   -- 'assistant' | 'manual'
  created_by  uuid references auth.users on delete set null default auth.uid(),
  created_at  timestamptz not null default now()
);
create index on public.family_memories (family_id, created_at);

alter table public.family_memories enable row level security;

-- Anyone in the family (including the wall display) can read and add memories;
-- only parents can delete them.
create policy memories_read   on public.family_memories for select using (public.is_family_member(family_id));
create policy memories_insert on public.family_memories for insert with check (public.is_family_member(family_id));
create policy memories_delete on public.family_memories for delete using (public.is_family_parent(family_id));
