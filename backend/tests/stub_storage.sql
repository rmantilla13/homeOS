-- Just enough of Supabase Storage and Realtime to apply and test the
-- Supabase-only migrations (20261006000002, 20261007000005). Loaded after
-- stub_auth.sql.
create schema storage;
grant usage on schema storage to anon, authenticated, service_role;

create table storage.buckets (
  id          text primary key,
  name        text not null unique,
  public      boolean default false,
  created_at  timestamptz default now()
);

create table storage.objects (
  id          uuid primary key default gen_random_uuid(),
  bucket_id   text references storage.buckets (id),
  name        text not null,
  owner       uuid default auth.uid(),
  metadata    jsonb,
  created_at  timestamptz default now(),
  updated_at  timestamptz default now(),
  unique (bucket_id, name)
);
alter table storage.objects enable row level security;
grant select on storage.buckets to anon, authenticated, service_role;
grant select, insert, update, delete on storage.objects to anon, authenticated, service_role;

-- Same as Supabase's: every path segment except the file name.
create function storage.foldername(name text) returns text[] language plpgsql as $$
declare
  _parts text[];
begin
  select string_to_array(name, '/') into _parts;
  return _parts[1:array_length(_parts, 1) - 1];
end $$;

-- Publishing needs wal_level=logical to stream, not to exist.
set client_min_messages = error;
create publication supabase_realtime;
reset client_min_messages;
