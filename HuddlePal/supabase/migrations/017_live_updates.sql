-- Live updates: deposits, comments and reactions go out over Supabase
-- Realtime (Postgres changes), so a huddle that's open updates as soon as
-- someone posts, comments or reacts. Realtime checks every row against the
-- table's RLS with the listener's own token: nobody hears about a row they
-- couldn't read. Only where the supabase_realtime publication exists (every
-- Supabase project has it). Safe to re-run.

begin;

do $$
declare
  t text;
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    foreach t in array array['deposits', 'comments', 'reactions'] loop
      if not exists (
        select 1 from pg_publication_tables
        where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t
      ) then
        execute format('alter publication supabase_realtime add table public.%I', t);
      end if;
    end loop;
  end if;
end $$;

commit;
