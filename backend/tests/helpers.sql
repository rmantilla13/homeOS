-- Test helpers, loaded after the migrations and seed. Each test file runs in
-- its own copy of that database.
create schema tests;
grant usage on schema tests to anon, authenticated, service_role, supabase_auth_admin;

-- Act as a signed-in user, the way PostgREST does per request (role plus JWT
-- claims). A null id means an anonymous caller.
create function tests.login(uid uuid) returns void language plpgsql as $$
begin
  perform set_config('role', 'none', false);
  perform set_config('request.jwt.claim.sub', coalesce(uid::text, ''), false);
  perform set_config('request.jwt.claim.role', case when uid is null then 'anon' else 'authenticated' end, false);
  perform set_config('role', case when uid is null then 'anon' else 'authenticated' end, false);
end $$;

-- The service role key used by edge functions: no user, bypasses RLS.
create function tests.login_service() returns void language plpgsql as $$
begin
  perform set_config('role', 'none', false);
  perform set_config('request.jwt.claim.sub', '', false);
  perform set_config('request.jwt.claim.role', 'service_role', false);
  perform set_config('role', 'service_role', false);
end $$;

-- Back to the superuser with no JWT (migrations, SQL editor).
create function tests.logout() returns void language plpgsql as $$
begin
  perform set_config('role', 'none', false);
  perform set_config('request.jwt.claim.sub', '', false);
  perform set_config('request.jwt.claim.role', '', false);
end $$;

create function tests.ok(cond boolean, what text) returns void language plpgsql as $$
begin
  if cond is not true then
    raise exception 'FAIL: %', what;
  end if;
end $$;

create function tests.eq(actual anyelement, expected anyelement, what text) returns void language plpgsql as $$
begin
  if actual is distinct from expected then
    raise exception 'FAIL: % (expected %, got %)', what, coalesce(expected::text, 'null'), coalesce(actual::text, 'null');
  end if;
end $$;

-- Runs `statement` and expects it to fail with a message LIKE `expected`.
create function tests.throws(statement text, expected text, what text) returns void language plpgsql as $$
begin
  begin
    execute statement;
  exception when others then
    if sqlerrm like expected then
      return;
    end if;
    raise exception 'FAIL: % (expected error "%", got "%")', what, expected, sqlerrm;
  end;
  raise exception 'FAIL: % (expected error "%", but it succeeded)', what, expected;
end $$;

-- Rows `statement` touched (for UPDATE/DELETE that RLS may filter to zero).
create function tests.affected(statement text) returns int language plpgsql as $$
declare
  n int;
begin
  execute statement;
  get diagnostics n = row_count;
  return n;
end $$;

grant execute on all functions in schema tests to anon, authenticated, service_role, supabase_auth_admin;
