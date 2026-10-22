-- The slice of a Supabase project that schema.sql relies on, recreated for
-- the local test database (PGlite): the extensions schema with pgcrypto, the
-- anon / authenticated / service_role roles with Supabase's default grants,
-- auth.users + auth.uid() (read from the request's JWT subject, the way
-- PostgREST sets it), storage.objects + storage.foldername() so the
-- storage policies run against the same rows the Storage API would query,
-- and pg_net + Vault as far as the push triggers use them (net.http_post
-- records each request instead of sending it; Vault secrets are plain rows).

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

-- pg_net's net.http_post, recording instead of sending.
create schema if not exists net;
create table net.http_requests (
  id bigserial primary key,
  url text,
  body jsonb,
  headers jsonb,
  timeout_milliseconds integer
);
create function net.http_post(
  url text,
  body jsonb default '{}'::jsonb,
  params jsonb default '{}'::jsonb,
  headers jsonb default '{"Content-Type": "application/json"}'::jsonb,
  timeout_milliseconds integer default 5000
) returns bigint language sql as $$
  insert into net.http_requests (url, body, headers, timeout_milliseconds)
  values (url, body, headers, timeout_milliseconds)
  returning id
$$;

-- Supabase Vault: secrets as plain rows behind the decrypted_secrets view.
create schema if not exists vault;
create table vault.secrets (name text primary key, secret text not null);
create view vault.decrypted_secrets as select name, secret as decrypted_secret from vault.secrets;
