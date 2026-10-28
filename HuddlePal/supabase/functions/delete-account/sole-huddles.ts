// Deletes the Storage files of huddles public.delete_sole_huddles already
// removed. Kept paths (a reported deposit's poster and clip) stay. Tested
// from supabase/tests/delete-account.test.mjs; index.ts wires Supabase.

import { listHuddleFolderFiles, STORAGE_REMOVE_BATCH } from "../_shared/huddle-storage.ts";

export interface SoleHuddleDeletion {
  huddle_id: string;
  kept_paths: string[];
}

/** The jsonb array from delete_sole_huddles, or anything that isn't one. */
export function soleHuddleDeletions(data: unknown): SoleHuddleDeletion[] {
  let parsed: unknown = data;
  if (typeof data === "string") {
    try {
      parsed = JSON.parse(data);
    } catch {
      return [];
    }
  }
  if (!Array.isArray(parsed)) return [];
  return parsed.flatMap((row) => {
    if (!row || typeof row !== "object") return [];
    const huddleId = (row as { huddle_id?: unknown }).huddle_id;
    if (typeof huddleId !== "string") return [];
    const kept = (row as { kept_paths?: unknown }).kept_paths;
    return [{
      huddle_id: huddleId,
      kept_paths: Array.isArray(kept) ? kept.filter((path): path is string => typeof path === "string") : [],
    }];
  });
}

/**
 * For each deleted huddle, list both folder casings and remove every file
 * except kept paths, a hundred at a time. One huddle's failure does not
 * skip the others; the first failures are raised after the rest.
 */
export async function removeSoleHuddleFiles(
  deleted: readonly SoleHuddleDeletion[],
  listFolder: (folder: string) => Promise<string[]>,
  removeFiles: (paths: string[]) => Promise<void>,
): Promise<void> {
  const failures: string[] = [];
  for (const row of deleted) {
    try {
      const keep = new Set(row.kept_paths);
      const paths = (await listHuddleFolderFiles(row.huddle_id, listFolder)).filter((path) => !keep.has(path));
      for (let i = 0; i < paths.length; i += STORAGE_REMOVE_BATCH) {
        await removeFiles(paths.slice(i, i + STORAGE_REMOVE_BATCH));
      }
    } catch (e) {
      const detail = e instanceof Error ? `${e.name}: ${e.message}` : String(e);
      failures.push(`${row.huddle_id} ${detail}`);
    }
  }
  if (failures.length) throw new Error(failures.join("; "));
}
