// Local stand-in for the Supabase database: real Postgres (PGlite, in
// process) with supabase-stub.sql, then schema.sql exactly as deployed.
// Requests run the way PostgREST runs them: in a transaction, as the
// `authenticated` role (or `anon` without a user), with the JWT subject set.

import { PGlite } from '@electric-sql/pglite'
import { pgcrypto } from '@electric-sql/pglite/contrib/pgcrypto'
import { readFileSync, readdirSync } from 'node:fs'
import { randomUUID } from 'node:crypto'

const read = (path) => readFileSync(new URL(path, import.meta.url), 'utf8')

export const STUB_SQL = read('./supabase-stub.sql')
export const SCHEMA_SQL = read('../schema.sql')
/** schema.sql as production last ran it (b1af561, "start the backend fresh"). */
export const DEPLOYED_SQL = read('./fixtures/deployed-schema-b1af561.sql')

/** supabase/migrations/*.sql in the order they are applied. */
export function migrations() {
  const dir = new URL('../migrations/', import.meta.url)
  return readdirSync(dir)
    .filter((name) => name.endsWith('.sql'))
    .sort()
    .map((name) => ({ name, sql: readFileSync(new URL(name, dir), 'utf8') }))
}

/**
 * HUDDLE_DB=fresh (default): schema.sql on an empty database.
 * HUDDLE_DB=migrated: the deployed schema, then every migration — the path
 * production takes. `npm test` runs the whole suite in both modes.
 */
export const MODE = process.env.HUDDLE_DB === 'migrated' ? 'migrated' : 'fresh'

/** A fresh database with the full schema applied. */
export async function freshDatabase({ mode = MODE } = {}) {
  const db = new PGlite({ extensions: { pgcrypto } })
  await db.exec(STUB_SQL)
  if (mode === 'migrated') {
    await db.exec(DEPLOYED_SQL)
    for (const { sql } of migrations()) await db.exec(sql)
  } else {
    await db.exec(SCHEMA_SQL)
  }
  return db
}

/** Runs `fn(tx)` as one API request by `uid` (null = anonymous). */
export function as(db, uid, fn) {
  return db.transaction(async (tx) => {
    await tx.query(`select set_config('request.jwt.claim.sub', $1, true)`, [uid ?? ''])
    await tx.exec(`set local role ${uid ? 'authenticated' : 'anon'}`)
    return fn(tx)
  })
}

/** One statement as `uid`; resolves to its rows. */
export async function q(db, uid, sql, params = []) {
  const result = await as(db, uid, (tx) => tx.query(sql, params))
  return result.rows
}

/** One statement as `uid`; resolves to the number of rows it touched. */
export async function affected(db, uid, sql, params = []) {
  const result = await as(db, uid, (tx) => tx.query(sql, params))
  return result.affectedRows ?? 0
}

/** Superuser read (the dashboard / service role view of the data). */
export async function admin(db, sql, params = []) {
  return (await db.query(sql, params)).rows
}

/** One statement as the service role (an edge function's admin client). */
export async function service(db, sql, params = []) {
  const result = await db.transaction(async (tx) => {
    await tx.exec('set local role service_role')
    return tx.query(sql, params)
  })
  return result.rows
}

export async function serverToday(db, offsetDays = 0) {
  const rows = await admin(
    db,
    `select to_char(now() + make_interval(days => $1), 'YYYY-MM-DD') as d`,
    [offsetDays],
  )
  return rows[0].d
}

/** Creates only the authentication record, before profile/age activation. */
export async function authUser(db, name) {
  const id = randomUUID()
  await admin(db, `insert into auth.users (id, email) values ($1, $2)`, [id, `${name}@example.test`])
  return id
}

/** Creates an eligible account through the same atomic RPC as the app. */
export async function signUp(db, name) {
  const id = await authUser(db, name)
  const [{ available }] = await admin(db, `select to_regprocedure('public.complete_profile(text,text,date)') is not null as available`)
  if (available) {
    await q(db, id, `select * from complete_profile($1, 'E5484D', '1995-06-14')`, [name])
  } else {
    // Migration regression tests deliberately start before age activation.
    await q(db, id, `insert into profiles (id, display_name) values ($1, $2)`, [id, name])
  }
  return id
}

export async function createHuddle(db, uid, name = 'Huddle') {
  const rows = await q(db, uid, `select * from create_huddle($1, '🏔', null)`, [name])
  return rows[0]
}

export async function joinHuddle(db, uid, code) {
  const rows = await q(db, uid, `select * from join_huddle($1, null)`, [code])
  return rows[0]
}

/** A syntactically valid wrapped photo key (the DB only checks the shape). */
export const WRAPPED_KEY = 'A'.repeat(80)
/** A syntactically valid 32-byte base64 key. */
export const PUBLIC_KEY = (c = 'A') => `${c.repeat(43)}=`

export async function deposit(db, uid, huddleId, dayKey, { caption = null } = {}) {
  const rows = await q(
    db,
    uid,
    `insert into deposits (huddle_id, author_id, storage_path, wrapped_photo_key, day_key, caption)
     values ($1, $2, $3, $4, $5, $6) returning *`,
    [huddleId, uid, `${huddleId}/${randomUUID()}.jpg`, WRAPPED_KEY, dayKey, caption],
  )
  return rows[0]
}

/** A video deposit as the app posts one: its poster at storage_path, the clip next to it. */
export async function videoDeposit(db, uid, huddleId, dayKey, { durationMs = 6000 } = {}) {
  const name = `${huddleId}/${randomUUID()}`
  const rows = await q(
    db,
    uid,
    `insert into deposits (huddle_id, author_id, storage_path, video_path, media_type, duration_ms, wrapped_photo_key, day_key)
     values ($1, $2, $3, $4, 'video', $5, $6, $7) returning *`,
    [huddleId, uid, `${name}.jpg`, `${name}.mp4`, durationMs, WRAPPED_KEY, dayKey],
  )
  return rows[0]
}

/**
 * Gives `uid` HuddlePals+, as verify-subscription records it: until
 * `expiresIn` from now (an interval; negative for one that has run out),
 * with an optional billing grace period after that, or refunded.
 * Returns the subscription's original transaction id.
 */
export async function grantPlus(db, uid, { expiresIn = '30 days', graceIn = null, revoked = false } = {}) {
  const otid = String(2_000_000_000_000_000 + Math.floor(Math.random() * 1e12))
  await admin(
    db,
    `insert into user_entitlements (original_transaction_id, user_id, product_id, transaction_id, environment,
                                    purchased_at, expires_at, grace_period_expires_at, revoked_at, transaction_signed_at)
     values ($1, $2, 'com.huddlepals.ios.plus.monthly', $1, 'Production', now(), now() + $3::interval,
             now() + $4::interval, case when $5 then now() end, now())`,
    [otid, uid, expiresIn, graceIn, revoked],
  )
  return otid
}

/** Plus ran out a minute ago (no renewal, no grace). */
export async function endPlus(db, otid) {
  await admin(
    db,
    `update user_entitlements set expires_at = now() - interval '1 minute', grace_period_expires_at = null
     where original_transaction_id = $1`,
    [otid],
  )
}

/** Puts an object row in storage, as the Storage API does after an upload. */
export async function storeObject(db, name) {
  await admin(db, `insert into storage.objects (bucket_id, name) values ('deposits', $1)`, [name])
}

export { randomUUID }
