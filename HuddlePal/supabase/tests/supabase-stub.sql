-- The slice of a Supabase project that schema.sql relies on, recreated for
-- the local test database (PGlite): the extensions schema with pgcrypto, the
-- anon / authenticated / service_role roles with Supabase's default grants,
-- auth.users + auth.uid() (read from the request's JWT subject, the way
-- PostgREST sets it), and storage.objects + storage.foldername() so the
-- storage policies run against the same rows the Storage API would query.

create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;
create schema if not exists auth;
create schema if not exists storage;

create role anon nologin noinherit;
create role authenticated nologin noinherit;
create role service_role nologin noinherit bypassrls;

grant usage on schema public, extensions, auth, storage to anon, authenticated, service_role;
grant execute on all functions in schema extensions to anon, authenticated, service_role;
alter default privileges in schema public grant all on tables to anon, authenticated, service_role;
alter default privileges in schema public grant all on functions to anon, authenticated, service_role;
alter default privileges in schema public grant all on sequences to anon, authenticated, service_role;

create table auth.users (
  id uuid primary key,
  email text,
  created_at timestamptz default now()
);

create function auth.uid() returns uuid language sql stable as $$
  select coalesce(
    nullif(current_setting('request.jwt.claim.sub', true), ''),
    (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub')
  )::uuid
$$;
grant execute on function auth.uid() to anon, authenticated, service_role;

create table storage.buckets (
  id text primary key,
  name text not null,
  public boolean default false
);

-- owner is the uploader's user id (the Storage API sets it from the JWT),
-- owner_id the same as text. Storage versions that still keep
-- objects_owner_fkey refuse to delete a user who owns objects; the stub
-- keeps it, so the tests cover that worst case.
create table storage.objects (
  id uuid primary key default gen_random_uuid(),
  bucket_id text references storage.buckets (id),
  name text not null,
  owner uuid constraint objects_owner_fkey references auth.users (id),
  owner_id text,
  created_at timestamptz default now(),
  unique (bucket_id, name)
);
alter table storage.objects enable row level security;
grant all on storage.objects to anon, authenticated, service_role;

-- Supabase's own definition.
create function storage.foldername(name text) returns text[] language plpgsql as $$
declare _parts text[];
begin
  select string_to_array(name, '/') into _parts;
  return _parts[1:array_length(_parts,1)-1];
end $$;
grant execute on function storage.foldername(text) to anon, authenticated, service_role;

insert into storage.buckets (id, name) values ('deposits', 'deposits');
