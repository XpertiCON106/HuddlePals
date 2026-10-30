-- Website analytics for huddlepals.com: basic page visits, sessions and
-- events on the site's public pages, for the site's admin
-- dashboard. Five new tables, all named analytics_, and the functions the
-- website's Worker calls with the service role key. No existing table
-- changes, and the app never touches any of it. Safe to re-run.
--
-- 019 is reserved for 019_age_eligibility.sql (legal-fixes branch).

begin;

create table if not exists public.analytics_visitors (
  id uuid primary key,
  fingerprint text,
  first_seen timestamptz not null default now(),
  last_seen timestamptz not null default now(),
  user_agent text,
  is_admin boolean not null default false
);

create table if not exists public.analytics_sessions (
  id uuid primary key,
  visitor_id uuid references public.analytics_visitors (id) on delete set null,
  started_at timestamptz not null default now(),
  last_seen timestamptz not null default now(),
  landing_path text,
  referer text,
  referrer_host text,
  utm jsonb not null default '{}'::jsonb,
  path_history jsonb not null default '[]'::jsonb,
  is_admin boolean not null default false
);

create table if not exists public.analytics_visits (
  id uuid primary key default gen_random_uuid(),
  visitor_id uuid,
  session_id uuid,
  visited_at timestamptz not null default now(),
  path text,
  landing_path text,
  referer text,
  referrer_host text,
  utm jsonb not null default '{}'::jsonb,
  ip text,
  user_agent text,
  accept_language text,
  country text,
  region text,
  region_code text,
  city text,
  postal_code text,
  latitude double precision,
  longitude double precision,
  timezone text,
  continent text,
  metro_code text,
  is_eu_country boolean,
  asn text,
  as_organization text,
  colo text,
  http_protocol text,
  tls_version text,
  tls_cipher text,
  client_tcp_rtt integer,
  bot_score integer,
  verified_bot boolean,
  is_vpn boolean,
  is_proxy boolean,
  is_tor boolean,
  is_hosting boolean,
  isp text,
  headers jsonb not null default '{}'::jsonb,
  client jsonb not null default '{}'::jsonb,
  fingerprint text,
  screen_w integer,
  screen_h integer,
  viewport_w integer,
  viewport_h integer,
  pixel_ratio numeric,
  color_scheme text,
  reduced_motion boolean,
  net_type text,
  net_downlink numeric,
  net_rtt integer,
  save_data boolean,
  device_memory numeric,
  cpu_cores integer,
  ttfb_ms integer,
  fcp_ms integer,
  dom_ready_ms integer,
  load_ms integer,
  duration_ms integer,
  visible_ms integer,
  focus_ms integer,
  scroll_depth numeric,
  is_admin boolean not null default false
);

create table if not exists public.analytics_events (
  id uuid primary key default gen_random_uuid(),
  visit_id uuid references public.analytics_visits (id) on delete cascade,
  visitor_id uuid,
  session_id uuid,
  occurred_at timestamptz not null default now(),
  name text not null,
  path text,
  props jsonb not null default '{}'::jsonb,
  is_admin boolean not null default false
);

-- Cached visitor lookups (helper data), refreshed at most once a week.
create table if not exists public.analytics_ip_enrichment (
  ip text primary key,
  is_vpn boolean,
  is_proxy boolean,
  is_tor boolean,
  is_hosting boolean,
  isp text,
  payload jsonb not null default '{}'::jsonb,
  fetched_at timestamptz not null default now()
);

alter table public.analytics_visitors enable row level security;
alter table public.analytics_sessions enable row level security;
alter table public.analytics_visits enable row level security;
alter table public.analytics_events enable row level security;
alter table public.analytics_ip_enrichment enable row level security;
revoke all on public.analytics_visitors, public.analytics_sessions, public.analytics_visits,
  public.analytics_events, public.analytics_ip_enrichment from anon, authenticated;
grant all on public.analytics_visitors, public.analytics_sessions, public.analytics_visits,
  public.analytics_events, public.analytics_ip_enrichment to service_role;

create index if not exists analytics_visits_time_idx on public.analytics_visits (visited_at desc);
create index if not exists analytics_visits_admin_time_idx on public.analytics_visits (is_admin, visited_at desc);
create index if not exists analytics_visits_visitor_idx on public.analytics_visits (visitor_id);
create index if not exists analytics_visits_session_idx on public.analytics_visits (session_id);
create index if not exists analytics_visits_ip_idx on public.analytics_visits (ip);
create index if not exists analytics_sessions_visitor_idx on public.analytics_sessions (visitor_id);
create index if not exists analytics_events_visit_idx on public.analytics_events (visit_id);
create index if not exists analytics_events_name_time_idx on public.analytics_events (name, occurred_at desc);
create index if not exists analytics_events_time_idx on public.analytics_events (occurred_at desc);

-- A time zone Postgres knows, or UTC.
create or replace function public.analytics_tz(tz text)
returns text
language plpgsql stable security definer set search_path = '' as $$
begin
  perform now() at time zone tz;
  return tz;
exception when others then
  return 'UTC';
end $$;
revoke execute on function public.analytics_tz(text) from public, anon, authenticated;
grant execute on function public.analytics_tz(text) to service_role;

-- The dashboard's numbers for the last range_days days (null = all time),
-- with "today" and the series (hourly for 24 hours, daily up to 180 days,
-- weekly beyond) in time zone tz. The admin's own visits
-- (is_admin) are left out. Service role only.
create or replace function public.analytics_summary(range_days integer default 30, tz text default 'UTC')
returns jsonb
language sql stable security definer set search_path = '' as $$
  with p as (
    select public.analytics_tz(tz) as zone,
           case when range_days is null then '-infinity'::timestamptz
                else now() - make_interval(days => greatest(range_days, 1)) end as since,
           case when range_days is null or range_days > 180 then 'week'
                when range_days = 1 then 'hour' else 'day' end as unit
  ),
  v as (
    select a.* from public.analytics_visits a, p
     where a.is_admin = false and a.visited_at >= p.since
  )
  select jsonb_build_object(
    'totals', (
      select jsonb_build_object(
        'visits', count(*),
        'unique', count(distinct a.visitor_id),
        'today', count(*) filter (where a.visited_at >= date_trunc('day', now() at time zone p.zone) at time zone p.zone),
        'd7', count(*) filter (where a.visited_at >= now() - interval '7 days'),
        'd30', count(*) filter (where a.visited_at >= now() - interval '30 days'),
        'live', count(*) filter (where a.visited_at >= now() - interval '5 minutes'),
        'range', count(*) filter (where a.visited_at >= p.since),
        'rangeUnique', count(distinct a.visitor_id) filter (where a.visited_at >= p.since)
      )
      from public.analytics_visits a, p
      where a.is_admin = false
    ),
    'series', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'date', to_char(b.bucket, case when p.unit = 'hour' then 'YYYY-MM-DD"T"HH24:00' else 'YYYY-MM-DD' end),
        'visits', coalesce(d.visits, 0),
        'unique', coalesce(d.uniques, 0)
      ) order by b.bucket), '[]'::jsonb)
      from p
      cross join lateral generate_series(
        date_trunc(p.unit, case when range_days is null
          then coalesce((select min(visited_at) from v), now()) at time zone p.zone
          when p.unit = 'hour' then (now() - interval '23 hours') at time zone p.zone
          else (now() - make_interval(days => greatest(range_days - 1, 0))) at time zone p.zone end),
        date_trunc(p.unit, now() at time zone p.zone),
        case p.unit when 'week' then interval '1 week' when 'hour' then interval '1 hour' else interval '1 day' end
      ) as b(bucket)
      left join (
        select date_trunc(p.unit, v.visited_at at time zone p.zone) as bucket,
               count(*) as visits, count(distinct v.visitor_id) as uniques
          from v, p
         group by 1
      ) d on d.bucket = b.bucket
    ),
    'countries', (
      select coalesce(jsonb_agg(jsonb_build_object('name', t.name, 'count', t.n) order by t.n desc, t.name), '[]'::jsonb)
      from (select country as name, count(*) as n from v where coalesce(country, '') <> ''
            group by 1 order by 2 desc, 1 limit 12) t
    ),
    'cities', (
      select coalesce(jsonb_agg(jsonb_build_object('name', t.name, 'count', t.n) order by t.n desc, t.name), '[]'::jsonb)
      from (select city || coalesce(', ' || nullif(region_code, ''), '') || coalesce(', ' || country, '') as name, count(*) as n
              from v where coalesce(city, '') <> ''
             group by 1 order by 2 desc, 1 limit 12) t
    ),
    'pages', (
      select coalesce(jsonb_agg(jsonb_build_object('name', t.name, 'count', t.n) order by t.n desc, t.name), '[]'::jsonb)
      from (select coalesce(nullif(path, ''), '/') as name, count(*) as n from v
             group by 1 order by 2 desc, 1 limit 12) t
    ),
    'referrers', (
      select coalesce(jsonb_agg(jsonb_build_object('name', t.name, 'count', t.n) order by t.n desc, t.name), '[]'::jsonb)
      from (select coalesce(nullif(referrer_host, ''), 'direct') as name, count(*) as n from v
             group by 1 order by 2 desc, 1 limit 12) t
    ),
    'devices', (
      select coalesce(jsonb_agg(jsonb_build_object('name', t.name, 'count', t.n) order by t.n desc, t.name), '[]'::jsonb)
      from (select coalesce(nullif(client ->> 'device', ''), 'unknown') as name, count(*) as n from v
             group by 1 order by 2 desc, 1 limit 8) t
    ),
    'browsers', (
      select coalesce(jsonb_agg(jsonb_build_object('name', t.name, 'count', t.n) order by t.n desc, t.name), '[]'::jsonb)
      from (select coalesce(nullif(client ->> 'browser', ''), 'unknown') as name, count(*) as n from v
             group by 1 order by 2 desc, 1 limit 8) t
    ),
    'os', (
      select coalesce(jsonb_agg(jsonb_build_object('name', t.name, 'count', t.n) order by t.n desc, t.name), '[]'::jsonb)
      from (select coalesce(nullif(client ->> 'os', ''), 'unknown') as name, count(*) as n from v
             group by 1 order by 2 desc, 1 limit 8) t
    ),
    'pins', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', x.id, 'lat', x.latitude, 'lon', x.longitude, 'visitedAt', x.visited_at,
        'city', x.city, 'region', x.region, 'regionCode', x.region_code,
        'postalCode', x.postal_code, 'country', x.country, 'path', x.path,
        'visitorId', x.visitor_id, 'device', x.device
      ) order by x.visited_at desc), '[]'::jsonb)
      from (select id, latitude, longitude, visited_at, city, region, region_code, postal_code,
                   country, path, visitor_id, coalesce(client ->> 'device', '') as device
              from v where latitude is not null and longitude is not null
             order by visited_at desc limit 1000) x
    )
  )
$$;
revoke execute on function public.analytics_summary(integer, text) from public, anon, authenticated;
grant execute on function public.analytics_summary(integer, text) to service_role;

-- The Experience section: page timing, attention, devices, clicks and
-- script errors over the same range. Service role only.
create or replace function public.analytics_experience(range_days integer default 30)
returns jsonb
language sql stable security definer set search_path = '' as $$
  with p as (
    select case when range_days is null then '-infinity'::timestamptz
                else now() - make_interval(days => greatest(range_days, 1)) end as since
  ),
  v as (
    select a.* from public.analytics_visits a, p
     where a.is_admin = false and a.visited_at >= p.since
  ),
  e as (
    select a.* from public.analytics_events a, p
     where a.is_admin = false and a.occurred_at >= p.since
  )
  select jsonb_build_object(
    'timing', (
      select jsonb_build_object(
        'ttfb', round(percentile_cont(0.5) within group (order by ttfb_ms)),
        'fcp', round(percentile_cont(0.5) within group (order by fcp_ms)),
        'domReady', round(percentile_cont(0.5) within group (order by dom_ready_ms)),
        'load', round(percentile_cont(0.5) within group (order by load_ms)),
        'samples', count(load_ms)
      ) from v
    ),
    'attention', (
      select jsonb_build_object(
        'duration', round(percentile_cont(0.5) within group (order by duration_ms)),
        'visible', round(percentile_cont(0.5) within group (order by visible_ms)),
        'focus', round(percentile_cont(0.5) within group (order by focus_ms)),
        'scroll', round(avg(scroll_depth)),
        'samples', count(duration_ms)
      ) from v where duration_ms is not null
    ),
    'schemes', (
      select coalesce(jsonb_agg(jsonb_build_object('name', t.name, 'count', t.n) order by t.n desc, t.name), '[]'::jsonb)
      from (select coalesce(color_scheme, 'unknown') as name, count(*) as n from v
             group by 1 order by 2 desc, 1 limit 4) t
    ),
    'motion', (
      select coalesce(jsonb_agg(jsonb_build_object('name', t.name, 'count', t.n) order by t.n desc, t.name), '[]'::jsonb)
      from (select case reduced_motion when true then 'reduce' when false then 'no preference' else 'unknown' end as name,
                   count(*) as n from v group by 1 order by 2 desc, 1 limit 4) t
    ),
    'connections', (
      select coalesce(jsonb_agg(jsonb_build_object('name', t.name, 'count', t.n) order by t.n desc, t.name), '[]'::jsonb)
      from (select coalesce(net_type, 'unknown') || case when save_data then ' (save data)' else '' end as name,
                   count(*) as n from v group by 1 order by 2 desc, 1 limit 8) t
    ),
    'screens', (
      select coalesce(jsonb_agg(jsonb_build_object('name', t.name, 'count', t.n) order by t.n desc, t.name), '[]'::jsonb)
      from (select coalesce(screen_w || '×' || screen_h || coalesce(' @' || trim_scale(round(pixel_ratio, 2)) || 'x', ''), 'unknown') as name,
                   count(*) as n from v group by 1 order by 2 desc, 1 limit 8) t
    ),
    'hardware', (
      select coalesce(jsonb_agg(jsonb_build_object('name', t.name, 'count', t.n) order by t.n desc, t.name), '[]'::jsonb)
      from (select coalesce(cpu_cores || ' cores', '? cores') || ' · ' || coalesce(device_memory || ' GB', '? GB') as name,
                   count(*) as n from v group by 1 order by 2 desc, 1 limit 8) t
    ),
    'clicks', (
      select coalesce(jsonb_agg(jsonb_build_object('name', t.name, 'count', t.n) order by t.n desc, t.name), '[]'::jsonb)
      from (select coalesce(nullif(props ->> 'label', ''), nullif(props ->> 'id', ''), props ->> 'tag', 'unknown') as name,
                   count(*) as n from e where name = 'click' group by 1 order by 2 desc, 1 limit 10) t
    ),
    'outbound', (
      select coalesce(jsonb_agg(jsonb_build_object('name', t.name, 'count', t.n) order by t.n desc, t.name), '[]'::jsonb)
      from (select coalesce(props ->> 'href', 'unknown') as name, count(*) as n
              from e where name = 'outbound_click' group by 1 order by 2 desc, 1 limit 10) t
    ),
    'errors', jsonb_build_object(
      'count', (select count(*) from e where name = 'js_error'),
      'recent', (
        select coalesce(jsonb_agg(to_jsonb(x) order by x.at desc), '[]'::jsonb)
        from (select occurred_at as at, path, visit_id as "visitId",
                     props ->> 'kind' as kind, props ->> 'message' as message,
                     props ->> 'source' as source, props ->> 'line' as line
                from e where name = 'js_error' order by occurred_at desc limit 10) x
      )
    )
  )
$$;
revoke execute on function public.analytics_experience(integer) from public, anon, authenticated;
grant execute on function public.analytics_experience(integer) to service_role;

-- Deletes visits (and their events), then any session and visitor left with
-- no visits, and any cached helper data no visit uses any more. Returns how
-- many visits went. Service role only.
create or replace function public.analytics_delete_visits(ids uuid[])
returns integer
language plpgsql security definer set search_path = '' as $$
declare
  v_sessions uuid[];
  v_visitors uuid[];
  v_ips text[];
  v_count integer;
begin
  select coalesce(array_agg(distinct session_id) filter (where session_id is not null), '{}'),
         coalesce(array_agg(distinct visitor_id) filter (where visitor_id is not null), '{}'),
         coalesce(array_agg(distinct ip) filter (where ip is not null), '{}')
    into v_sessions, v_visitors, v_ips
    from public.analytics_visits where id = any(ids);
  delete from public.analytics_events where visit_id = any(ids);
  delete from public.analytics_visits where id = any(ids);
  get diagnostics v_count = row_count;
  delete from public.analytics_events e
   where e.session_id = any(v_sessions)
     and not exists (select 1 from public.analytics_visits v where v.session_id = e.session_id);
  delete from public.analytics_sessions s
   where s.id = any(v_sessions)
     and not exists (select 1 from public.analytics_visits v where v.session_id = s.id);
  delete from public.analytics_visitors r
   where r.id = any(v_visitors)
     and not exists (select 1 from public.analytics_visits v where v.visitor_id = r.id)
     and not exists (select 1 from public.analytics_sessions s where s.visitor_id = r.id);
  delete from public.analytics_ip_enrichment i
   where i.ip = any(v_ips)
     and not exists (select 1 from public.analytics_visits v where v.ip = i.ip);
  return v_count;
end $$;
revoke execute on function public.analytics_delete_visits(uuid[]) from public, anon, authenticated;
grant execute on function public.analytics_delete_visits(uuid[]) to service_role;

-- Empties the five analytics_ tables and nothing else. Service role only.
create or replace function public.analytics_clear_all()
returns integer
language plpgsql security definer set search_path = '' as $$
declare
  v_count integer;
begin
  select count(*) into v_count from public.analytics_visits;
  delete from public.analytics_events where true;
  delete from public.analytics_visits where true;
  delete from public.analytics_sessions where true;
  delete from public.analytics_visitors where true;
  delete from public.analytics_ip_enrichment where true;
  return v_count;
end $$;
revoke execute on function public.analytics_clear_all() from public, anon, authenticated;
grant execute on function public.analytics_clear_all() to service_role;

-- Retention: deletes visits older than keep_days (with their events, and
-- sessions and visitors left with none) and helper data older than 30 days.
-- The website's Worker runs it daily with keep_days = 395 (13 months).
-- Service role only.
create or replace function public.analytics_prune(keep_days integer default 395)
returns integer
language plpgsql security definer set search_path = '' as $$
declare
  v_ids uuid[];
  v_count integer := 0;
begin
  select coalesce(array_agg(id), '{}') into v_ids from public.analytics_visits
   where visited_at < now() - make_interval(days => greatest(keep_days, 1));
  if cardinality(v_ids) > 0 then
    v_count := public.analytics_delete_visits(v_ids);
  end if;
  delete from public.analytics_events
   where occurred_at < now() - make_interval(days => greatest(keep_days, 1));
  delete from public.analytics_sessions s
   where s.last_seen < now() - make_interval(days => greatest(keep_days, 1))
     and not exists (select 1 from public.analytics_visits v where v.session_id = s.id);
  delete from public.analytics_visitors r
   where r.last_seen < now() - make_interval(days => greatest(keep_days, 1))
     and not exists (select 1 from public.analytics_visits v where v.visitor_id = r.id)
     and not exists (select 1 from public.analytics_sessions s where s.visitor_id = r.id);
  delete from public.analytics_ip_enrichment where fetched_at < now() - interval '30 days';
  return v_count;
end $$;
revoke execute on function public.analytics_prune(integer) from public, anon, authenticated;
grant execute on function public.analytics_prune(integer) to service_role;

commit;
