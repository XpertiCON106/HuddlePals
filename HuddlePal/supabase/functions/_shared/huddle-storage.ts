// Storage object names are case-sensitive. The iOS app writes a huddle's
// folder as the uppercase UUID (Foundation `UUID.uuidString`, see
// ComposeViewModel). Callers also pass the lowercase id. List both.

/** Page size for storage.list. */
export const STORAGE_LIST_PAGE = 1000;
/** storage.remove batch size. */
export const STORAGE_REMOVE_BATCH = 100;

export interface StorageListEntry {
  name: string;
  /** Present for a file. A folder prefix comes back with no id. */
  id?: string | null;
}

/**
 * Folder names to list for one huddle. A UUID with no a-f digits is the
 * same string in both cases, so it is returned once.
 */
export function huddleStorageFolders(huddleId: string): string[] {
  const lower = huddleId.toLowerCase();
  const upper = lower.toUpperCase();
  return lower === upper ? [lower] : [lower, upper];
}

/** Every file directly inside one folder, as "<folder>/<name>". */
export async function listStorageFolder(
  folder: string,
  listPage: (folder: string, offset: number, limit: number) => Promise<StorageListEntry[]>,
): Promise<string[]> {
  const paths: string[] = [];
  for (let offset = 0; ; offset += STORAGE_LIST_PAGE) {
    const data = await listPage(folder, offset, STORAGE_LIST_PAGE);
    for (const file of data) if (file.id) paths.push(`${folder}/${file.name}`);
    if (data.length < STORAGE_LIST_PAGE) return paths;
  }
}

/**
 * Files under both casings of a huddle folder. `listFolder` returns full
 * object paths. Each path is included once.
 */
export async function listHuddleFolderFiles(
  huddleId: string,
  listFolder: (folder: string) => Promise<string[]>,
): Promise<string[]> {
  const seen = new Set<string>();
  const paths: string[] = [];
  for (const folder of huddleStorageFolders(huddleId)) {
    for (const path of await listFolder(folder)) {
      if (!seen.has(path)) {
        seen.add(path);
        paths.push(path);
      }
    }
  }
  return paths;
}
