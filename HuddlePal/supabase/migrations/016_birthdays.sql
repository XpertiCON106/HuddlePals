-- Birthdays: asked when a profile is made (and once of accounts from
-- before), to keep HuddlePals to people 13 and older (Terms 2.1). Only the
-- account's owner can read or change theirs, and it goes with the profile.
-- The age rule allows a day for time zones: the app checks the age on the
-- person's own calendar. Safe to re-run.

begin;

create table if not exists public.profile_birthdates (
  user_id uuid primary key references public.profiles (id) on delete cascade,
  birth_date date not null check (birth_date >= date '1900-01-01')
);
alter table public.profile_birthdates enable row level security;
revoke all on public.profile_birthdates from anon, authenticated;
grant select, insert, update on public.profile_birthdates to authenticated;

drop policy if exists profile_birthdates_select on public.profile_birthdates;
create policy profile_birthdates_select on public.profile_birthdates for select
  using (user_id = auth.uid());
drop policy if exists profile_birthdates_insert on public.profile_birthdates;
create policy profile_birthdates_insert on public.profile_birthdates for insert
  with check (user_id = auth.uid() and birth_date <= (current_date - interval '13 years' + interval '1 day')::date);
drop policy if exists profile_birthdates_update on public.profile_birthdates;
create policy profile_birthdates_update on public.profile_birthdates for update
  using (user_id = auth.uid())
  with check (user_id = auth.uid() and birth_date <= (current_date - interval '13 years' + interval '1 day')::date);

commit;
