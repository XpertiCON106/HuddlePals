-- Server-side record of the Terms of Service: which version each account
-- agreed to, and when. Until now the agreement lived only on the device, so
-- nothing showed who had agreed to what. The app (TermsRecorder) writes a
-- row once someone who tapped Agree is signed in. Safe to re-run.

begin;

create table if not exists public.terms_acceptances (
  user_id uuid not null references auth.users (id) on delete cascade,
  -- TermsOfService.version: the Terms' "Last updated" date.
  version text not null check (version ~ '^\d{4}-\d{2}-\d{2}$'),
  -- When Agree was tapped, by the device's clock.
  accepted_at timestamptz not null,
  -- When the server stored the record, by its own clock.
  recorded_at timestamptz not null default now(),
  -- The app's version and build, e.g. "1.0 (10)".
  app_version text check (app_version is null or char_length(app_version) <= 40),
  primary key (user_id, version)
);

alter table public.terms_acceptances enable row level security;

-- Record your own and read them back; no updates, no deletes.
drop policy if exists terms_acceptances_select_own on public.terms_acceptances;
create policy terms_acceptances_select_own on public.terms_acceptances for select
  using (user_id = auth.uid());
drop policy if exists terms_acceptances_insert_own on public.terms_acceptances;
create policy terms_acceptances_insert_own on public.terms_acceptances for insert
  with check (user_id = auth.uid());

-- recorded_at is the server's clock, never the app's.
revoke insert on public.terms_acceptances from anon, authenticated;
grant insert (user_id, version, accepted_at, app_version) on public.terms_acceptances to authenticated;

commit;
