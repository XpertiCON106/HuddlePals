-- QA-02: invite codes could be guessed with unlimited tries, and a member
-- who gets in receives the huddle key from the other members' apps
-- automatically, so a guessed code opens the whole photo archive. Each user
-- now gets 10 wrong codes per hour. Safe to re-run.

begin;

-- Wrong invite-code guesses, per user. Codes are 6 characters from a
-- 31-character alphabet (~887M codes), few enough to enumerate with
-- unlimited tries, and a successful guess gets the huddle key shared
-- automatically. join_huddle refuses a caller with 10 misses in the last hour.
-- Only that SECURITY DEFINER function touches this table: RLS is on and there
-- are no policies, so clients can neither read nor write it.
create table if not exists public.join_attempts (
  user_id uuid not null references auth.users (id) on delete cascade,
  attempted_at timestamptz not null default now()
);
create index if not exists join_attempts_user_time on public.join_attempts (user_id, attempted_at);
alter table public.join_attempts enable row level security;

-- Validates the invite code and enforces the 8-member cap atomically.
-- `p_day_key` is the caller's local today, stored as their join day — the
-- streak starts waiting on them the day after. An unknown code returns no
-- row (the app reads that as "no huddle for that code"): raising instead
-- would roll back the recorded miss.
create or replace function public.join_huddle(p_code text, p_day_key text default null)
returns setof public.huddles
language plpgsql security definer set search_path = public as $$
declare
  v_huddle huddles%rowtype;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  delete from join_attempts where user_id = auth.uid() and attempted_at < now() - interval '1 hour';
  if (select count(*) from join_attempts where user_id = auth.uid()) >= 10 then
    raise exception 'too_many_attempts';
  end if;
  select * into v_huddle from huddles where upper(invite_code) = upper(trim(p_code));
  if not found then
    insert into join_attempts (user_id) values (auth.uid());
    return;
  end if;
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

commit;
