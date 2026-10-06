-- Minimal stand-in for Supabase so the schema can be tested on plain Postgres:
-- the auth schema, the API roles with Supabase's default grants, and pgcrypto
-- in `extensions` where Supabase keeps it.
create schema extensions;
create extension if not exists pgcrypto with schema extensions;

create schema auth;
create table auth.users (
  id                  uuid primary key,
  email               text,
  raw_user_meta_data  jsonb default '{}',
  raw_app_meta_data   jsonb default '{}',
  created_at          timestamptz default now(),
  last_sign_in_at     timestamptz,
  banned_until        timestamptz
);
create function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $$;

-- Roles are cluster-wide, so they may already exist.
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then create role anon nologin; end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then create role authenticated nologin; end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role') then create role service_role nologin bypassrls; end if;
  if not exists (select 1 from pg_roles where rolname = 'supabase_auth_admin') then create role supabase_auth_admin nologin; end if;
end $$;

-- Like Supabase: the API roles can use public and call auth.uid(), and new
-- objects in public are granted to them (RLS and explicit revokes do the rest).
-- They get nothing on auth.users.
grant usage on schema public, auth, extensions to anon, authenticated, service_role;
alter default privileges in schema public grant all on tables    to anon, authenticated, service_role;
alter default privileges in schema public grant all on sequences to anon, authenticated, service_role;
alter default privileges in schema public grant all on functions to anon, authenticated, service_role;
