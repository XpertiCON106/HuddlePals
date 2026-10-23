-- Deleting an account deleted every report that account had filed, with the
-- reported photo's key: the only way to open that photo again. What the
-- operator reports to NCMEC must be kept for a year (18 U.S.C. 2258A(h)), so
-- a report now outlives its reporter: the reporter becomes null instead.
-- Safe to re-run.

begin;

alter table public.reports alter column reporter_id drop not null;

alter table public.reports drop constraint if exists reports_reporter_id_fkey;
alter table public.reports
  add constraint reports_reporter_id_fkey
  foreign key (reporter_id) references public.profiles (id) on delete set null;

commit;
