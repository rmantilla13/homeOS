-- Assistant conversations: threads and messages per person (or display), and
-- per-request usage for limits and the admin console. See
-- docs/PLATFORM_SPEC.md §1.5 and §2.1.

create table public.assistant_threads (
  id          uuid primary key default gen_random_uuid(),
  family_id   uuid not null references public.families on delete cascade,
  owner_id    uuid not null references auth.users on delete cascade default auth.uid(),   -- person or display device
  title       text not null default 'New chat',
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  archived    boolean not null default false
);
create index on public.assistant_threads (owner_id, updated_at desc);

create table public.assistant_messages (
  id          bigint generated always as identity primary key,
  thread_id   uuid not null references public.assistant_threads on delete cascade,
  family_id   uuid not null references public.families on delete cascade,
  role        text not null check (role in ('user', 'assistant')),
  -- Clients write rows here that the assistant replays as history, so keep
  -- them bounded; a 16k-token reply fits easily.
  content     text not null check (length(content) <= 100000),
  actions     jsonb not null default '[]',
  mode        text not null default 'chat' check (mode in ('chat', 'quick')),
  created_by  uuid references auth.users on delete set null default auth.uid(),
  created_at  timestamptz not null default now()
);
create index on public.assistant_messages (thread_id, id);

-- Written by the assistant function with the service role.
create table public.assistant_usage (
  id                 bigint generated always as identity primary key,
  family_id          uuid references public.families on delete cascade,
  user_id            uuid references auth.users on delete set null,
  thread_id          uuid references public.assistant_threads on delete set null,
  mode               text not null default 'chat',
  model              text not null,
  input_tokens       int not null default 0,
  output_tokens      int not null default 0,
  cache_read_tokens  int not null default 0,
  tool_calls         int not null default 0,
  created_at         timestamptz not null default now()
);
create index on public.assistant_usage (family_id, created_at);

create trigger assistant_threads_touch before update on public.assistant_threads
  for each row execute function public.touch_updated_at();

-- A message always belongs to its thread's family, so clients may leave
-- family_id out.
create function public.prepare_assistant_message()
returns trigger
language plpgsql security definer set search_path = public as $$
begin
  select t.family_id into new.family_id from public.assistant_threads t where t.id = new.thread_id;
  return new;
end $$;

create trigger assistant_messages_prepare before insert on public.assistant_messages
  for each row execute function public.prepare_assistant_message();

-- ───────────────────────── Row-level security ─────────────────────────

alter table public.assistant_threads  enable row level security;
alter table public.assistant_messages enable row level security;
alter table public.assistant_usage    enable row level security;

-- Your own threads, in a family you're (still) part of. Another member of the
-- same family can't read them.
create policy threads_own on public.assistant_threads for all
  using (owner_id = auth.uid() and public.is_family_member(family_id))
  with check (owner_id = auth.uid() and public.is_family_member(family_id));

-- Messages follow their thread. Append-only: no update or delete policies;
-- they go when the thread does.
create policy messages_read on public.assistant_messages for select
  using (exists (select 1 from public.assistant_threads t
                 where t.id = thread_id and t.owner_id = auth.uid() and public.is_family_member(t.family_id)));
create policy messages_insert on public.assistant_messages for insert
  with check (coalesce(created_by, auth.uid()) = auth.uid()
              and exists (select 1 from public.assistant_threads t
                          where t.id = thread_id and t.owner_id = auth.uid() and public.is_family_member(t.family_id)));

create policy usage_read on public.assistant_usage for select using (public.is_platform_admin());

revoke execute on function public.prepare_assistant_message() from public, anon, authenticated;
