// schema.sql builds fresh databases; supabase/migrations/ upgrades the one
// production already runs. Both paths must land on the same schema, and the
// migrations must be safe to re-run.

import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { freshDatabase, admin, migrations } from './harness.mjs'

const squash = (s) => (s ?? '').replace(/\s+/g, ' ').trim()

/** Everything that affects behaviour: columns, constraints, indexes, policies, functions, triggers, grants. */
async function catalog(db) {
  const sections = {
    columns: `select table_name, column_name, data_type, column_default, is_nullable
              from information_schema.columns where table_schema = 'public' order by 1, 2`,
    constraints: `select conrelid::regclass::text as rel, conname, pg_get_constraintdef(oid) as def
                  from pg_constraint where connamespace = 'public'::regnamespace order by 1, 2`,
    indexes: `select tablename, indexname, indexdef from pg_indexes where schemaname = 'public' order by 1, 2`,
    policies: `select schemaname, tablename, policyname, cmd, roles::text, qual, with_check
               from pg_policies where schemaname in ('public', 'storage') order by 1, 2, 3`,
    functions: `select proname, pg_get_function_identity_arguments(oid) as args, prosecdef,
                       array_to_string(proconfig, ',') as config, prosrc
                from pg_proc where pronamespace = 'public'::regnamespace order by 1, 2`,
    triggers: `select tgrelid::regclass::text as rel, tgname, pg_get_triggerdef(oid) as def
               from pg_trigger where not tgisinternal order by 1, 2`,
    tableGrants: `select grantee, table_name, privilege_type from information_schema.table_privileges
                  where table_schema = 'public' order by 1, 2, 3`,
    columnGrants: `select grantee, table_name, column_name, privilege_type from information_schema.column_privileges
                   where table_schema = 'public' and grantee in ('anon', 'authenticated') order by 1, 2, 3, 4`,
  }
  const out = {}
  for (const [name, sql] of Object.entries(sections)) {
    out[name] = (await admin(db, sql)).map((row) =>
      Object.fromEntries(Object.entries(row).map(([k, v]) => [
        k,
        // A constraint added NOT VALID (so legacy rows aren't rechecked)
        // behaves the same for every new write.
        typeof v === 'string' ? squash(v).replace(/ NOT VALID$/, '') : v,
      ])),
    )
  }
  return out
}

describe('migrations', () => {
  it('the deployed schema plus every migration equals schema.sql', async () => {
    const fresh = await catalog(await freshDatabase({ mode: 'fresh' }))
    const migrated = await catalog(await freshDatabase({ mode: 'migrated' }))
    for (const section of Object.keys(fresh)) {
      assert.deepEqual(migrated[section], fresh[section], `${section} differ`)
    }
  })

  it('huddles that lost their keeper before the fix get one back (QA-04)', async () => {
    const { PGlite } = await import('@electric-sql/pglite')
    const { pgcrypto } = await import('@electric-sql/pglite/contrib/pgcrypto')
    const { STUB_SQL, DEPLOYED_SQL, signUp, createHuddle, joinHuddle, affected } = await import('./harness.mjs')
    const db = new PGlite({ extensions: { pgcrypto } })
    await db.exec(STUB_SQL)
    await db.exec(DEPLOYED_SQL)
    const A = await signUp(db, 'Ada')
    const B = await signUp(db, 'Ben')
    const C = await signUp(db, 'Cy')
    const h = await createHuddle(db, A)
    await joinHuddle(db, B, h.invite_code)
    await joinHuddle(db, C, h.invite_code)
    await affected(db, A, 'delete from memberships where user_id = $1', [A])
    assert.deepEqual(await admin(db, `select 1 from memberships where role = 'keeper'`), [], 'the old schema loses the keeper')
    for (const { sql } of migrations()) await db.exec(sql)
    assert.deepEqual(await admin(db, `select user_id from memberships where role = 'keeper'`), [{ user_id: B }])
  })

  it('key copies held by people who already left are removed (QA-05)', async () => {
    const { PGlite } = await import('@electric-sql/pglite')
    const { pgcrypto } = await import('@electric-sql/pglite/contrib/pgcrypto')
    const { STUB_SQL, DEPLOYED_SQL, signUp, createHuddle, joinHuddle, affected, q, PUBLIC_KEY, WRAPPED_KEY } = await import('./harness.mjs')
    const db = new PGlite({ extensions: { pgcrypto } })
    await db.exec(STUB_SQL)
    await db.exec(DEPLOYED_SQL)
    const A = await signUp(db, 'Ada')
    const B = await signUp(db, 'Ben')
    const h = await createHuddle(db, A)
    await joinHuddle(db, B, h.invite_code)
    for (const [u, c] of [[A, 'A'], [B, 'B']]) await q(db, u, 'insert into user_keys (user_id, public_key) values ($1, $2)', [u, PUBLIC_KEY(c)])
    await q(db, A, 'select init_huddle_key($1, $2, $3, $4)', [h.id, WRAPPED_KEY, PUBLIC_KEY('E'), PUBLIC_KEY('A')])
    await q(db, A, 'select share_huddle_key($1, $2, $3, $4, $5)', [h.id, B, WRAPPED_KEY, PUBLIC_KEY('F'), PUBLIC_KEY('B')])
    await affected(db, B, 'delete from memberships where user_id = $1', [B])
    assert.equal((await q(db, B, 'select * from huddle_keys')).length, 1, 'the old schema leaves the copy behind')
    for (const { sql } of migrations()) await db.exec(sql)
    assert.deepEqual(await q(db, B, 'select * from huddle_keys'), [])
    assert.equal((await q(db, A, 'select * from huddle_keys')).length, 1, 'current members keep theirs')
  })

  it('reports filed before the fix survive their reporter deleting the account', async () => {
    const { PGlite } = await import('@electric-sql/pglite')
    const { pgcrypto } = await import('@electric-sql/pglite/contrib/pgcrypto')
    const { STUB_SQL, DEPLOYED_SQL, signUp, createHuddle, joinHuddle, deposit, serverToday, q } = await import('./harness.mjs')
    const db = new PGlite({ extensions: { pgcrypto } })
    await db.exec(STUB_SQL)
    await db.exec(DEPLOYED_SQL)
    const A = await signUp(db, 'Ada')
    const B = await signUp(db, 'Ben')
    const h = await createHuddle(db, A)
    await joinHuddle(db, B, h.invite_code)
    const dep = await deposit(db, A, h.id, await serverToday(db))
    await q(db, B, 'insert into reports (reporter_id, deposit_id) values ($1, $2)', [B, dep.id])
    for (const { sql } of migrations()) await db.exec(sql)
    await admin(db, 'delete from auth.users where id = $1', [B])
    assert.deepEqual(await admin(db, 'select reporter_id, deposit_id from reports'), [{ reporter_id: null, deposit_id: dep.id }])
  })

  it('every migration can be applied twice', async () => {
    const db = await freshDatabase({ mode: 'migrated' })
    for (const { name, sql } of migrations()) {
      await assert.doesNotReject(db.exec(sql), name)
    }
  })
})
