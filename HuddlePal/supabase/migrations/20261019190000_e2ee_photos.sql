-- Vault — end-to-end encrypted deposit photos.
--
-- Run once in the Supabase SQL Editor on a database created from an older
-- schema.sql (it is idempotent, so a second run is harmless). It mirrors the
-- "end-to-end encrypted photos" section of schema.sql plus the new
-- deposits / reports columns.
--
-- Manual steps that SQL can't do (Dashboard → Storage → deposits → Edit):
--   • Allowed MIME types: add application/octet-stream (vault photos are now
--     ciphertext); keep image/jpeg (profile photos stay plain JPEG).
--     image/heic is no longer uploaded by the app and may be dropped.
--   • Keep the 5 MB file size limit.
--
-- Any deposit created BEFORE this migration is a plaintext photo the
-- operator can view, and the app can't display it any more (it expects
-- ciphertext). The database was empty when this shipped; to check:
--   select id, storage_path from public.deposits where wrapped_photo_key is null;
-- and delete such rows plus their Storage objects by hand if any exist.

-- ------------------------------------------------------------ deposits
alter table public.deposits add column if not exists wrapped_photo_key text;
alter table public.deposits add column if not exists enc_version smallint not null default 1;

-- New rows must be encrypted. NOT VALID: enforced for every insert from now
-- on without failing on pre-migration rows (see the note above).
alter table public.deposits drop constraint if exists deposits_photo_encrypted;
alter table public.deposits add constraint deposits_photo_encrypted check (
  wrapped_photo_key ~ '^[A-Za-z0-9+/]{80}$' and enc_version = 1
) not valid;

-- ------------------------------------------------------------- reports
alter table public.reports add column if not exists photo_key text;
alter table public.reports drop constraint if exists reports_photo_key_format;
alter table public.reports add constraint reports_photo_key_format check (
  photo_key is null or photo_key ~ '^[A-Za-z0-9+/]{43}=$'
);

-- ------------------------------------------------------------ key tables
create table if not exists public.user_keys (
  user_id uuid primary key references auth.users (id) on delete cascade,
  public_key text not null check (public_key ~ '^[A-Za-z0-9+/]{43}=$'),
  created_at timestamptz not null default now()
);

create table if not exists public.vault_keys (
  vault_id uuid not null references public.vaults (id) on delete cascade,
  user_id uuid not null references auth.users (id) on delete cascade,
  wrapped_key text not null check (wrapped_key ~ '^[A-Za-z0-9+/]{80}$'),
  ephemeral_public_key text not null check (ephemeral_public_key ~ '^[A-Za-z0-9+/]{43}=$'),
  recipient_public_key text not null check (recipient_public_key ~ '^[A-Za-z0-9+/]{43}=$'),
  wrapped_by uuid references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),
  primary key (vault_id, user_id)
);

alter table public.user_keys  enable row level security;
alter table public.vault_keys enable row level security;

drop policy if exists user_keys_select on public.user_keys;
drop policy if exists user_keys_insert on public.user_keys;
drop policy if exists user_keys_update on public.user_keys;
create policy user_keys_select on public.user_keys for select
  using (shares_vault_with(user_id));
create policy user_keys_insert on public.user_keys for insert
  with check (user_id = auth.uid());
create policy user_keys_update on public.user_keys for update
  using (user_id = auth.uid()) with check (user_id = auth.uid());

-- Own copies only; no direct writes (the RPCs below are the only writers).
drop policy if exists vault_keys_select_own on public.vault_keys;
create policy vault_keys_select_own on public.vault_keys for select
  using (user_id = auth.uid());

-- ------------------------------------------------------------------ RPCs
create or replace function public.init_vault_key(
  p_vault uuid, p_wrapped_key text, p_ephemeral_public_key text, p_recipient_public_key text
)
returns boolean
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if not is_vault_member(p_vault) then raise exception 'not_a_member'; end if;
  if p_recipient_public_key is distinct from
     (select public_key from user_keys where user_id = auth.uid()) then
    raise exception 'stale_public_key';
  end if;
  perform 1 from vaults where id = p_vault for update;
  if exists (select 1 from vault_keys k
             join memberships m on m.vault_id = k.vault_id and m.user_id = k.user_id
             where k.vault_id = p_vault) then
    return false;
  end if;
  insert into vault_keys (vault_id, user_id, wrapped_key, ephemeral_public_key,
                          recipient_public_key, wrapped_by)
    values (p_vault, auth.uid(), p_wrapped_key, p_ephemeral_public_key,
            p_recipient_public_key, auth.uid())
    on conflict (vault_id, user_id) do nothing;
  return found;
end $$;

create or replace function public.vault_key_recipients(p_vault uuid)
returns table (user_id uuid, public_key text)
language sql stable security definer set search_path = public as $$
  select m.user_id, k.public_key
  from memberships m
  join user_keys k on k.user_id = m.user_id
  left join vault_keys vk on vk.vault_id = m.vault_id and vk.user_id = m.user_id
  where m.vault_id = p_vault
    and is_vault_member(p_vault)
    and m.user_id <> auth.uid()
    and (vk.user_id is null or vk.recipient_public_key <> k.public_key);
$$;

create or replace function public.share_vault_key(
  p_vault uuid, p_user uuid, p_wrapped_key text, p_ephemeral_public_key text,
  p_recipient_public_key text
)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if p_user = auth.uid() then raise exception 'cannot_share_with_self'; end if;
  if not is_vault_member(p_vault) then raise exception 'not_a_member'; end if;
  if not exists (select 1 from memberships where vault_id = p_vault and user_id = p_user) then
    raise exception 'recipient_not_member';
  end if;
  if p_recipient_public_key is distinct from
     (select public_key from user_keys where user_id = p_user) then
    raise exception 'stale_public_key';
  end if;
  insert into vault_keys (vault_id, user_id, wrapped_key, ephemeral_public_key,
                          recipient_public_key, wrapped_by)
    values (p_vault, p_user, p_wrapped_key, p_ephemeral_public_key,
            p_recipient_public_key, auth.uid())
    on conflict (vault_id, user_id) do update
      set wrapped_key = excluded.wrapped_key,
          ephemeral_public_key = excluded.ephemeral_public_key,
          recipient_public_key = excluded.recipient_public_key,
          wrapped_by = excluded.wrapped_by,
          created_at = now()
      where vault_keys.wrapped_by = auth.uid()
         or vault_keys.recipient_public_key is distinct from excluded.recipient_public_key;
end $$;

-- PostgREST caches the schema; make the new tables/RPCs visible right away.
notify pgrst, 'reload schema';
