// The delete-huddle request, independent of the Supabase client so who may
// delete a huddle and which files go are testable on their own
// (supabase/tests/delete-huddle.test.mjs). index.ts wires the real services.

import { listHuddleFolderFiles, STORAGE_REMOVE_BATCH } from "../_shared/huddle-storage.ts";

export interface DeleteHuddleServices {
  /** The caller's user id, from their access token; null if it isn't valid. */
  authenticate(accessToken: string): Promise<string | null>;
  /**
   * public.delete_huddle(huddle, user): deletes the huddle's rows if the
   * user keeps it, and returns the Storage paths to keep (a reported
   * deposit's files). Throws with the database's message on a refusal.
   */
  deleteRows(huddleId: string, userId: string): Promise<string[]>;
  /** Every file directly inside this deposits folder, as "<folder>/<name>". */
  listFiles(folder: string): Promise<string[]>;
  /** Deletes these paths from the deposits bucket. */
  removeFiles(paths: string[]): Promise<void>;
  /** Server-side log. Never handed a token. */
  log(event: string, detail?: string): void;
}

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export async function handleDeleteHuddle(req: Request, services: DeleteHuddleServices): Promise<Response> {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  const accessToken = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
  const userId = accessToken ? await services.authenticate(accessToken) : null;
  if (!userId) return json({ error: "not_authenticated" }, 401);

  let requested: unknown;
  try {
    ({ huddle_id: requested } = await req.json());
  } catch {
    return json({ error: "bad_request" }, 400);
  }
  if (typeof requested !== "string" || !UUID.test(requested)) return json({ error: "bad_request" }, 400);
  // UUIDs compare either way in the database. Storage names do not: the app
  // writes the uppercase id, and older files may sit under the lowercase one.
  const huddleId = requested.toLowerCase();

  // 1. The rows, in one transaction: only the keeper gets past this.
  let kept: string[];
  try {
    kept = await services.deleteRows(huddleId, userId);
  } catch (e) {
    const message = e instanceof Error ? e.message : String(e);
    if (message.includes("not_keeper")) return json({ error: "not_keeper" }, 403);
    if (message.includes("huddle_not_found")) return json({ error: "huddle_not_found" }, 404);
    services.log("delete_huddle_failed", message);
    return json({ error: "delete_failed" }, 500);
  }

  // 2. The files: everything in either casing of the huddle's folder, except
  //    what a report keeps. The huddle is already gone, so a file that
  //    can't be deleted now is unreadable anyway (Storage lets only its
  //    members read it): logged for the operator, not an error for the keeper.
  const keep = new Set(kept);
  let removed = 0, failed = 0;
  try {
    const paths = (await listHuddleFolderFiles(huddleId, (folder) => services.listFiles(folder)))
      .filter((path) => !keep.has(path));
    for (let i = 0; i < paths.length; i += STORAGE_REMOVE_BATCH) {
      const batch = paths.slice(i, i + STORAGE_REMOVE_BATCH);
      try {
        await services.removeFiles(batch);
        removed += batch.length;
      } catch (e) {
        failed += batch.length;
        services.log("file_cleanup_failed", `${huddleId} ${errorName(e)}`);
      }
    }
  } catch (e) {
    failed = -1;
    services.log("file_list_failed", `${huddleId} ${errorName(e)}`);
  }
  services.log("huddle_deleted", `${huddleId} removed=${removed} failed=${failed} kept=${keep.size}`);
  return json({ deleted: true }, 200);
}

function errorName(e: unknown): string {
  return e instanceof Error ? `${e.name}: ${e.message}` : String(e);
}

function json(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...cors, "Content-Type": "application/json" },
  });
}
