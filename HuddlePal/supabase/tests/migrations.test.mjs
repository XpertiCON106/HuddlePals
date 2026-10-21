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

  it('every migration can be applied twice', async () => {
    const db = await freshDatabase({ mode: 'migrated' })
    for (const { name, sql } of migrations()) {
      await assert.doesNotReject(db.exec(sql), name)
    }
  })
})
