-- Minimal stand-in for Supabase auth so the schema can be tested on plain Postgres.
create extension if not exists pgcrypto;
create schema auth;
create table auth.users (id uuid primary key);
create function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $$;
create role authenticated nologin;
