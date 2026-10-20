-- Rename the app's group objects from vault to huddle.
--
-- One transaction. For a database that already applied schema.sql and
-- 20261019190000_e2ee_photos.sql. A fresh database should run the current
-- schema.sql instead of this file.
--
-- Does not touch the Supabase secrets schema named vault, or the
-- supabase_vault extension. Does not touch the storage bucket "deposits".
--
-- Constraint, index, and policy names below are PostgreSQL's defaults for
-- the unnamed constraints in schema.sql, plus the names that file and the
-- E2EE migration set explicitly.

begin;

-- Policies that call helper functions, or that will be recreated under a
-- new name. Drop them before the functions they depend on.
drop policy if exists profiles_select on public.profiles;
drop policy if exists vaults_select on public.vaults;
drop policy if exists vaults_update on public.vaults;
drop policy if exists memberships_select on public.memberships;
drop policy if exists deposits_select on public.deposits;
drop policy if exists deposits_insert on public.deposits;
drop policy if exists skips_select on public.skips;
drop policy if exists reactions_select on public.reactions;
drop policy if exists reactions_insert on public.reactions;
drop policy if exists comments_select on public.comments;
drop policy if exists comments_insert on public.comments;
drop policy if exists user_keys_select on public.user_keys;
drop policy if exists deposits_storage_read on storage.objects;
drop policy if exists deposits_storage_insert on storage.objects;

-- Callers first, then the helpers they depend on. Includes the pre-join-day
-- overloads (create_vault(text, text), join_vault(text)) when those are
-- still present. spend_skip_token, recompute_streak, and can_see_deposit
-- keep their names; they are dropped so parameter names and bodies can
-- change, then recreated below.
drop function if exists public.share_vault_key(uuid, uuid, text, text, text);
drop function if exists public.vault_key_recipients(uuid);
drop function if exists public.init_vault_key(uuid, text, text, text);
drop function if exists public.recompute_streak(uuid, text);
drop function if exists public.spend_skip_token(uuid, uuid, text);
drop function if exists public.join_vault(text, text);
drop function if exists public.join_vault(text);
drop function if exists public.create_vault(text, text, text);
drop function if exists public.create_vault(text, text);
drop function if exists public.vault_day_complete(uuid, text);
drop function if exists public.can_see_deposit(uuid);
drop function if exists public.shares_vault_with(uuid);
drop function if exists public.is_vault_keeper(uuid);
drop function if exists public.is_vault_member(uuid);

alter table public.vaults rename to huddles;
alter table public.vault_keys rename to huddle_keys;

alter table public.huddle_keys rename column vault_id to huddle_id;
alter table public.deposits rename column vault_id to huddle_id;
alter table public.memberships rename column vault_id to huddle_id;
alter table public.skips rename column vault_id to huddle_id;

alter table public.huddles rename constraint vaults_pkey to huddles_pkey;
alter table public.huddles rename constraint vaults_invite_code_key to huddles_invite_code_key;
alter table public.huddles rename constraint vaults_name_check to huddles_name_check;
alter table public.huddles rename constraint vaults_notification_hour_check to huddles_notification_hour_check;

alter table public.memberships rename constraint memberships_vault_id_fkey to memberships_huddle_id_fkey;
alter table public.memberships rename constraint memberships_user_id_vault_id_key to memberships_user_id_huddle_id_key;

alter table public.deposits rename constraint deposits_vault_id_fkey to deposits_huddle_id_fkey;
alter table public.deposits rename constraint deposits_vault_id_author_id_day_key_key to deposits_huddle_id_author_id_day_key_key;

alter table public.skips rename constraint skips_vault_id_fkey to skips_huddle_id_fkey;
alter table public.skips rename constraint skips_vault_id_user_id_day_key_key to skips_huddle_id_user_id_day_key_key;

alter table public.huddle_keys rename constraint vault_keys_pkey to huddle_keys_pkey;
alter table public.huddle_keys rename constraint vault_keys_vault_id_fkey to huddle_keys_huddle_id_fkey;
alter table public.huddle_keys rename constraint vault_keys_user_id_fkey to huddle_keys_user_id_fkey;
alter table public.huddle_keys rename constraint vault_keys_wrapped_by_fkey to huddle_keys_wrapped_by_fkey;
alter table public.huddle_keys rename constraint vault_keys_wrapped_key_check to huddle_keys_wrapped_key_check;
alter table public.huddle_keys rename constraint vault_keys_ephemeral_public_key_check to huddle_keys_ephemeral_public_key_check;
alter table public.huddle_keys rename constraint vault_keys_recipient_public_key_check to huddle_keys_recipient_public_key_check;

alter index public.deposits_vault_day rename to deposits_huddle_day;

-- This policy does not call a helper; only its name changes.
alter policy vault_keys_select_own on public.huddle_keys rename to huddle_keys_select_own;

-- Helpers, then the functions that call them. Same security, search_path,
-- volatility, and return types as the originals.
create or replace function public.is_huddle_member(v uuid)
returns boolean
language sql stable security definer set search_path = public as
$$ select exists (select 1 from memberships where huddle_id = v and user_id = auth.uid()); $$;

create or replace function public.is_huddle_keeper(v uuid)
returns boolean
language sql stable security definer set search_path = public as
$$ select exists (select 1 from memberships
                  where huddle_id = v and user_id = auth.uid() and role = 'keeper'); $$;

create or replace function public.shares_huddle_with(other uuid)
returns boolean
language sql stable security definer set search_path = public as
$$ select other = auth.uid() or exists (
     select 1 from memberships m1
     join memberships m2 on m1.huddle_id = m2.huddle_id
     where m1.user_id = auth.uid() and m2.user_id = other); $$;

create or replace function public.can_see_deposit(d uuid)
returns boolean
language sql stable security definer set search_path = public as
$$ select exists (select 1 from deposits dep
                  join memberships m on m.huddle_id = dep.huddle_id
                  where dep.id = d and m.user_id = auth.uid()); $$;

create or replace function public.huddle_day_complete(p_huddle uuid, p_day text)
returns boolean
language sql stable set search_path = public as $$
  with required as (
    select user_id from memberships
    where huddle_id = p_huddle
      and coalesce(joined_day_key, to_char(joined_at, 'YYYY-MM-DD')) < p_day
  ), covered as (
    select author_id as u from deposits where huddle_id = p_huddle and day_key = p_day
    union
    select user_id from skips where huddle_id = p_huddle and day_key = p_day
  )
  select exists (select 1 from required)
     and not exists (select 1 from required r where r.user_id not in (select u from covered where u is not null));
$$;

create or replace function public.create_huddle(p_name text, p_emoji text, p_day_key text default null)
returns setof public.huddles
language plpgsql security definer set search_path = public as $$
declare
  v_code text;
  v_huddle huddles%rowtype;
  alphabet constant text := 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  loop
    v_code := '';
    for i in 1..6 loop
      v_code := v_code || substr(alphabet, 1 + (get_byte(extensions.gen_random_bytes(1), 0) % length(alphabet)), 1);
    end loop;
    exit when not exists (select 1 from huddles where invite_code = v_code);
  end loop;
  insert into huddles (name, emoji, invite_code) values (p_name, p_emoji, v_code)
    returning * into v_huddle;
  insert into memberships (user_id, huddle_id, role, joined_day_key)
    values (auth.uid(), v_huddle.id, 'keeper', client_day_key(p_day_key));
  return next v_huddle;
end $$;

create or replace function public.join_huddle(p_code text, p_day_key text default null)
returns setof public.huddles
language plpgsql security definer set search_path = public as $$
declare
  v_huddle huddles%rowtype;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  select * into v_huddle from huddles where upper(invite_code) = upper(trim(p_code));
  if not found then raise exception 'invite_code_not_found'; end if;
  if exists (select 1 from memberships where huddle_id = v_huddle.id and user_id = auth.uid()) then
    raise exception 'already_member';
  end if;
  if (select count(*) from memberships where huddle_id = v_huddle.id) >= 8 then
    raise exception 'huddle_full';
  end if;
  insert into memberships (user_id, huddle_id, joined_day_key)
    values (auth.uid(), v_huddle.id, client_day_key(p_day_key));
  return next v_huddle;
end $$;

create or replace function public.spend_skip_token(p_huddle uuid, p_user uuid, p_day_key text)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_huddle_member(p_huddle) then raise exception 'not_a_member'; end if;
  update memberships set skip_tokens_remaining = skip_tokens_remaining - 1
    where huddle_id = p_huddle and user_id = auth.uid() and skip_tokens_remaining > 0;
  if not found then raise exception 'no_tokens_remaining'; end if;
  insert into skips (huddle_id, user_id, day_key) values (p_huddle, auth.uid(), p_day_key)
    on conflict do nothing;
end $$;

create or replace function public.recompute_streak(p_huddle uuid, p_today text)
returns int
language plpgsql security definer set search_path = public as $$
declare
  v_cursor date;
  v_count int := 0;
  v_last date := null;
begin
  if not is_huddle_member(p_huddle) then raise exception 'not_a_member'; end if;
  if p_today::date < (now()::date - 1) or p_today::date > (now()::date + 1) then
    raise exception 'invalid_day_key';
  end if;
  v_cursor := p_today::date;

  if not huddle_day_complete(p_huddle, to_char(v_cursor, 'YYYY-MM-DD')) then
    v_cursor := v_cursor - 1;
  end if;

  loop
    exit when v_count >= 36500 or not huddle_day_complete(p_huddle, to_char(v_cursor, 'YYYY-MM-DD'));
    v_count := v_count + 1;
    if v_last is null then v_last := v_cursor; end if;
    v_cursor := v_cursor - 1;
  end loop;

  update huddles set streak_count = v_count,
                    last_streak_day = case when v_last is null then null
                                           else to_char(v_last, 'YYYY-MM-DD') end
    where id = p_huddle;
  return v_count;
end $$;

create or replace function public.init_huddle_key(
  p_huddle uuid, p_wrapped_key text, p_ephemeral_public_key text, p_recipient_public_key text
)
returns boolean
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if not is_huddle_member(p_huddle) then raise exception 'not_a_member'; end if;
  if p_recipient_public_key is distinct from
     (select public_key from user_keys where user_id = auth.uid()) then
    raise exception 'stale_public_key';
  end if;
  perform 1 from huddles where id = p_huddle for update;
  if exists (select 1 from huddle_keys k
             join memberships m on m.huddle_id = k.huddle_id and m.user_id = k.user_id
             where k.huddle_id = p_huddle) then
    return false;
  end if;
  insert into huddle_keys (huddle_id, user_id, wrapped_key, ephemeral_public_key,
                          recipient_public_key, wrapped_by)
    values (p_huddle, auth.uid(), p_wrapped_key, p_ephemeral_public_key,
            p_recipient_public_key, auth.uid())
    on conflict (huddle_id, user_id) do nothing;
  return found;
end $$;

create or replace function public.huddle_key_recipients(p_huddle uuid)
returns table (user_id uuid, public_key text)
language sql stable security definer set search_path = public as $$
  select m.user_id, k.public_key
  from memberships m
  join user_keys k on k.user_id = m.user_id
  left join huddle_keys vk on vk.huddle_id = m.huddle_id and vk.user_id = m.user_id
  where m.huddle_id = p_huddle
    and is_huddle_member(p_huddle)
    and m.user_id <> auth.uid()
    and (vk.user_id is null or vk.recipient_public_key <> k.public_key);
$$;

create or replace function public.share_huddle_key(
  p_huddle uuid, p_user uuid, p_wrapped_key text, p_ephemeral_public_key text,
  p_recipient_public_key text
)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if p_user = auth.uid() then raise exception 'cannot_share_with_self'; end if;
  if not is_huddle_member(p_huddle) then raise exception 'not_a_member'; end if;
  if not exists (select 1 from memberships where huddle_id = p_huddle and user_id = p_user) then
    raise exception 'recipient_not_member';
  end if;
  if p_recipient_public_key is distinct from
     (select public_key from user_keys where user_id = p_user) then
    raise exception 'stale_public_key';
  end if;
  insert into huddle_keys (huddle_id, user_id, wrapped_key, ephemeral_public_key,
                          recipient_public_key, wrapped_by)
    values (p_huddle, p_user, p_wrapped_key, p_ephemeral_public_key,
            p_recipient_public_key, auth.uid())
    on conflict (huddle_id, user_id) do update
      set wrapped_key = excluded.wrapped_key,
          ephemeral_public_key = excluded.ephemeral_public_key,
          recipient_public_key = excluded.recipient_public_key,
          wrapped_by = excluded.wrapped_by,
          created_at = now()
      where huddle_keys.wrapped_by = auth.uid()
         or huddle_keys.recipient_public_key is distinct from excluded.recipient_public_key;
end $$;

-- DROP removed the previous grants. These match Supabase's default execute
-- privileges on functions created in public (anon, authenticated, service_role).
grant execute on function public.is_huddle_member(uuid) to anon, authenticated, service_role;
grant execute on function public.is_huddle_keeper(uuid) to anon, authenticated, service_role;
grant execute on function public.shares_huddle_with(uuid) to anon, authenticated, service_role;
grant execute on function public.can_see_deposit(uuid) to anon, authenticated, service_role;
grant execute on function public.huddle_day_complete(uuid, text) to anon, authenticated, service_role;
grant execute on function public.create_huddle(text, text, text) to anon, authenticated, service_role;
grant execute on function public.join_huddle(text, text) to anon, authenticated, service_role;
grant execute on function public.spend_skip_token(uuid, uuid, text) to anon, authenticated, service_role;
grant execute on function public.recompute_streak(uuid, text) to anon, authenticated, service_role;
grant execute on function public.init_huddle_key(uuid, text, text, text) to anon, authenticated, service_role;
grant execute on function public.huddle_key_recipients(uuid) to anon, authenticated, service_role;
grant execute on function public.share_huddle_key(uuid, uuid, text, text, text) to anon, authenticated, service_role;

create policy profiles_select on public.profiles for select
  using (shares_huddle_with(id));

create policy huddles_select on public.huddles for select
  using (is_huddle_member(id));
create policy huddles_update on public.huddles for update
  using (is_huddle_keeper(id)) with check (is_huddle_keeper(id));

create policy memberships_select on public.memberships for select
  using (is_huddle_member(huddle_id));

create policy deposits_select on public.deposits for select
  using (is_huddle_member(huddle_id));
create policy deposits_insert on public.deposits for insert
  with check (
    author_id = auth.uid()
    and is_huddle_member(huddle_id)
    and day_key >= to_char(now() - interval '2 days', 'YYYY-MM-DD')
    and day_key <= to_char(now() + interval '1 day',  'YYYY-MM-DD')
  );

create policy reactions_select on public.reactions for select
  using (can_see_deposit(deposit_id));
create policy reactions_insert on public.reactions for insert
  with check (user_id = auth.uid() and can_see_deposit(deposit_id));

create policy comments_select on public.comments for select
  using (can_see_deposit(deposit_id));
create policy comments_insert on public.comments for insert
  with check (user_id = auth.uid() and can_see_deposit(deposit_id));

create policy skips_select on public.skips for select
  using (is_huddle_member(huddle_id));

create policy user_keys_select on public.user_keys for select
  using (shares_huddle_with(user_id));

create policy deposits_storage_read on storage.objects for select
  using (
    bucket_id = 'deposits' and (
      (storage.foldername(name))[1] = 'avatars'
      or (
        try_uuid((storage.foldername(name))[1]) is not null
        and is_huddle_member(try_uuid((storage.foldername(name))[1]))
      )
    )
  );

create policy deposits_storage_insert on storage.objects for insert
  with check (
    bucket_id = 'deposits' and (
      (
        (storage.foldername(name))[1] = 'avatars'
        and (storage.foldername(name))[2] = auth.uid()::text
      )
      or (
        try_uuid((storage.foldername(name))[1]) is not null
        and is_huddle_member(try_uuid((storage.foldername(name))[1]))
      )
    )
  );

-- Fail the transaction if a public object or a storage policy still
-- carries the old name. The secrets schema is out of scope on purpose.
do $$
declare
  leftover text;
begin
  select string_agg(kind || ' ' || name, ', ' order by kind, name)
    into leftover
  from (
    select 'relation' as kind, c.relname as name
      from pg_class c
      join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public' and c.relname ilike '%vault%'
    union all
    select 'constraint', con.conname
      from pg_constraint con
      join pg_namespace n on n.oid = con.connamespace
     where n.nspname = 'public' and con.conname ilike '%vault%'
    union all
    select 'column', c.relname || '.' || a.attname
      from pg_attribute a
      join pg_class c on c.oid = a.attrelid
      join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public' and a.attnum > 0 and not a.attisdropped
       and c.relkind in ('r', 'p', 'v', 'm', 'f')
       and a.attname ilike '%vault%'
    union all
    select 'policy', n.nspname || '.' || pol.polname
      from pg_policy pol
      join pg_class c on c.oid = pol.polrelid
      join pg_namespace n on n.oid = c.relnamespace
     where n.nspname in ('public', 'storage')
       and (
         pol.polname ilike '%vault%'
         or coalesce(pg_get_expr(pol.polqual, pol.polrelid), '') ilike '%vault%'
         or coalesce(pg_get_expr(pol.polwithcheck, pol.polrelid), '') ilike '%vault%'
       )
    union all
    select 'function', p.proname
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and (p.proname ilike '%vault%' or p.prosrc ilike '%vault%')
  ) s;
  if leftover is not null then
    raise exception 'huddle rename left objects: %', leftover;
  end if;
end $$;

notify pgrst, 'reload schema';

commit;
