// Website analytics (analytics_ tables): only the service role, which the
// website's Worker uses, can read or write them or call their functions.
// The summary leaves the admin's own visits out; deleting visits also
// removes the sessions, visitors and lookup data nothing uses any more, and
// clearing empties the five analytics_ tables and nothing else.

import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { randomUUID } from 'node:crypto'
import { freshDatabase, q, admin, service, signUp } from './harness.mjs'

const TABLES = ['analytics_visitors', 'analytics_sessions', 'analytics_visits', 'analytics_events', 'analytics_ip_enrichment']
const FUNCTIONS = [
  'analytics_tz(text)',
  'analytics_summary(integer, text)',
  'analytics_experience(integer)',
  'analytics_delete_visits(uuid[])',
  'analytics_clear_all()',
  'analytics_prune(integer)',
]

/** One visitor in one session with `n` visits, `ago` back in time. */
async function seedVisits(db, { n = 1, ago = '1 minute', admin: isAdmin = false, ip = '198.51.100.7', city = 'San Jose' } = {}) {
  const visitor = randomUUID()
  const session = randomUUID()
  await service(db, `insert into analytics_visitors (id, is_admin) values ($1, $2)`, [visitor, isAdmin])
  await service(db, `insert into analytics_sessions (id, visitor_id, is_admin) values ($1, $2, $3)`, [session, visitor, isAdmin])
  const ids = []
  for (let i = 0; i < n; i++) {
    const [{ id }] = await service(
      db,
      `insert into analytics_visits (visitor_id, session_id, visited_at, path, ip, city, region_code, country,
                                     latitude, longitude, client, is_admin, load_ms, duration_ms)
       values ($1, $2, now() - $3::interval, '/', $4, $5, 'CA', 'US', 37.33, -121.89,
               '{"device":"desktop","browser":"Chrome","os":"macOS"}', $6, 800, 12000)
       returning id`,
      [visitor, session, ago, ip, city, isAdmin],
    )
    await service(db, `insert into analytics_events (visit_id, visitor_id, session_id, name, path, props, is_admin)
                       values ($1, $2, $3, 'click', '/', '{"label":"Join"}', $4)`, [id, visitor, session, isAdmin])
    ids.push(id)
  }
  await service(db, `insert into analytics_ip_enrichment (ip, is_vpn) values ($1, false) on conflict do nothing`, [ip])
  return { visitor, session, ids }
}

const count = async (db, table) => Number((await admin(db, `select count(*)::int as n from ${table}`))[0].n)

describe('website analytics', () => {
  it('app users and signed-out callers can neither read nor write the analytics_ tables', async () => {
    const db = await freshDatabase()
    const A = await signUp(db, 'Ada')
    await seedVisits(db)
    for (const table of TABLES) {
      for (const uid of [A, null]) {
        await assert.rejects(q(db, uid, `select * from ${table}`), /permission denied/, `${table} read`)
        await assert.rejects(q(db, uid, `delete from ${table}`), /permission denied/, `${table} delete`)
      }
    }
    await assert.rejects(q(db, A, `insert into analytics_visits (path) values ('/')`), /permission denied/)
    await assert.rejects(q(db, null, `insert into analytics_events (name) values ('click')`), /permission denied/)
    const rls = await admin(db, `select relname, relrowsecurity from pg_class where relname = any($1) order by relname`, [TABLES])
    assert.equal(rls.length, 5)
    assert.ok(rls.every((r) => r.relrowsecurity), 'RLS on')
    assert.equal(Number((await admin(db, `select count(*)::int as n from pg_policies where tablename = any($1)`, [TABLES]))[0].n), 0, 'no policies')
  })

  it('every analytics function is security definer, has a fixed search_path, and only the service role can call it', async () => {
    const db = await freshDatabase()
    const A = await signUp(db, 'Ada')
    for (const fn of FUNCTIONS) {
      const [row] = await admin(db, `select prosecdef, array_to_string(proconfig, ',') as config,
                                            has_function_privilege('anon', $1::regprocedure, 'execute') as anon,
                                            has_function_privilege('authenticated', $1::regprocedure, 'execute') as authed,
                                            has_function_privilege('service_role', $1::regprocedure, 'execute') as svc
                                       from pg_proc where oid = $1::regprocedure`, [`public.${fn}`])
      assert.equal(row.prosecdef, true, `${fn} security definer`)
      assert.equal(row.config, 'search_path=""', `${fn} search_path`)
      assert.deepEqual([row.anon, row.authed, row.svc], [false, false, true], fn)
    }
    await assert.rejects(q(db, A, `select analytics_summary(30, 'UTC')`), /permission denied/)
    await assert.rejects(q(db, null, `select analytics_clear_all()`), /permission denied/)
  })

  it('the summary counts visitors, leaves the admin out, and honours the range and time zone', async () => {
    const db = await freshDatabase()
    await seedVisits(db, { n: 3 })
    await seedVisits(db, { n: 1, ago: '20 days', city: 'Austin' })
    await seedVisits(db, { n: 1, ago: '200 days', city: 'Boston' })
    await seedVisits(db, { n: 4, admin: true })

    const sum = async (days, tz = 'UTC') => (await service(db, `select analytics_summary($1, $2) as s`, [days, tz]))[0].s
    const s7 = await sum(7, 'America/New_York')
    assert.equal(s7.totals.visits, 5, 'all-time, admin left out')
    assert.equal(s7.totals.unique, 3)
    assert.equal(s7.totals.live, 3)
    assert.equal(s7.totals.d7, 3)
    assert.equal(s7.totals.d30, 4)
    assert.equal(s7.totals.range, 3)
    assert.equal(s7.series.length, 7, 'one point a day')
    assert.equal(s7.series.reduce((n, d) => n + d.visits, 0), 3)
    assert.equal(s7.pins.length, 3)
    assert.deepEqual(s7.cities, [{ name: 'San Jose, CA, US', count: 3 }])

    const s1 = await sum(1, 'America/New_York')
    assert.equal(s1.series.length, 24, 'one point an hour for the last 24 hours')
    assert.match(s1.series[0].date, /^\d{4}-\d{2}-\d{2}T\d{2}:00$/)
    assert.equal(s1.series.reduce((n, d) => n + d.visits, 0), 3)
    assert.equal(s1.totals.range, 3)

    const s30 = await sum(30)
    assert.equal(s30.totals.range, 4)
    assert.equal(s30.series.length, 30)
    const all = await sum(null)
    assert.equal(all.totals.range, 5)
    assert.ok(all.series.length >= 28 && all.series.length <= 31, 'weekly points over all time')
    const bogus = await sum(7, 'Not/AZone')
    assert.equal(bogus.totals.range, 3, 'an unknown time zone falls back to UTC')

    const exp = (await service(db, `select analytics_experience(30) as e`))[0].e
    assert.equal(exp.timing.load, 800)
    assert.equal(exp.attention.duration, 12000)
    assert.deepEqual(exp.clicks, [{ name: 'Join', count: 5 }], 'events count by when they happened (all just now here)')
  })

  it('deleting visits removes their events and whatever session, visitor and lookup data is left unused', async () => {
    const db = await freshDatabase()
    const a = await seedVisits(db, { n: 2, ip: '198.51.100.1' })
    const b = await seedVisits(db, { n: 1, ip: '198.51.100.2' })

    const [{ n: one }] = await service(db, `select analytics_delete_visits($1) as n`, [[a.ids[0]]])
    assert.equal(one, 1)
    assert.equal(await count(db, 'analytics_visits'), 2)
    assert.equal(await count(db, 'analytics_sessions'), 2, 'a still has a visit')
    assert.equal(await count(db, 'analytics_ip_enrichment'), 2)

    const [{ n: two }] = await service(db, `select analytics_delete_visits($1) as n`, [[a.ids[1], b.ids[0]]])
    assert.equal(two, 2)
    for (const table of TABLES) assert.equal(await count(db, table), 0, `${table} empty`)
  })

  it('clear all empties exactly the five analytics_ tables', async () => {
    const db = await freshDatabase()
    const A = await signUp(db, 'Ada')
    await seedVisits(db, { n: 3 })
    await seedVisits(db, { n: 2, admin: true })
    const [{ n }] = await service(db, `select analytics_clear_all() as n`)
    assert.equal(n, 5)
    for (const table of TABLES) assert.equal(await count(db, table), 0, `${table} empty`)
    assert.deepEqual(await admin(db, `select id from profiles`), [{ id: A }], 'app data untouched')
  })

  it('prune drops what is older than the retention window and keeps the rest', async () => {
    const db = await freshDatabase()
    await seedVisits(db, { n: 2, ago: '400 days', ip: '198.51.100.9' })
    await admin(db, `update analytics_sessions set last_seen = now() - interval '400 days'`)
    await admin(db, `update analytics_visitors set last_seen = now() - interval '400 days'`)
    await seedVisits(db, { n: 1, ago: '1 day' })
    const [{ n }] = await service(db, `select analytics_prune(395) as n`)
    assert.equal(n, 2)
    assert.equal(await count(db, 'analytics_visits'), 1)
    assert.equal(await count(db, 'analytics_sessions'), 1)
    assert.equal(await count(db, 'analytics_visitors'), 1)
    assert.equal(await count(db, 'analytics_ip_enrichment'), 1)
  })
})
