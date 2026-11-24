/** Atomic manifest + bounded chunks stored exclusively in the supplied OS vault.
 * No plaintext persistence or memory fallback on vault failure. A failed write
 * leaves the previous manifest readable; inaccessible orphan chunks are cleaned
 * best-effort. Device reinstall/restore and real-device logout remain test gates.
 */
export interface Vault {
  get(key: string): Promise<string | null>;
  set(key: string, value: string): Promise<void>;
  remove(key: string): Promise<void>;
}
interface Manifest { generation: string; count: number }
const MAX_CHUNKS = 128;
const validKey = /^[a-zA-Z0-9._-]{1,180}$/;
const validGeneration = /^[a-zA-Z0-9-]{1,64}$/;
const failure = () => new Error('Secure session storage unavailable. Reauthenticate on an unlocked device.');

export function createSecureSessionStorage(vault: Vault, generation: () => string, clearLegacy: (key: string) => Promise<void>) {
  let tail: Promise<unknown> = Promise.resolve();
  const serial = <T>(key: string, action: () => Promise<T>): Promise<T> => {
    const task = tail.then(async () => {
      if (!validKey.test(key)) throw failure();
      await clearLegacy(key);
      return action();
    }).catch(() => { throw failure(); });
    tail = task.catch(() => undefined);
    return task;
  };
  const manifestKey = (key: string) => 'nforce.v1.' + key + '.manifest';
  const chunkKey = (key: string, g: string, i: number) => 'nforce.v1.' + key + '.' + g + '.' + i;
  const readManifest = async (key: string): Promise<Manifest | null> => {
    const raw = await vault.get(manifestKey(key));
    if (raw === null) return null;
    const m: unknown = JSON.parse(raw);
    if (typeof m !== 'object' || m === null || !('generation' in m) || !('count' in m) ||
        typeof m.generation !== 'string' || !validGeneration.test(m.generation) ||
        typeof m.count !== 'number' || !Number.isInteger(m.count) || m.count < 1 || m.count > MAX_CHUNKS) throw failure();
    return { generation: m.generation, count: m.count };
  };
  const clean = async (key: string, m: Manifest | null) => {
    if (m === null) return;
    for (let i = 0; i < m.count; i++) await vault.remove(chunkKey(key, m.generation, i));
  };
  return {
    getItem: (key: string) => serial(key, async () => {
      const m = await readManifest(key);
      if (m === null) return null;
      const chunks: string[] = [];
      for (let i = 0; i < m.count; i++) {
        const chunk = await vault.get(chunkKey(key, m.generation, i));
        if (chunk === null) throw failure();
        chunks.push(chunk);
      }
      return chunks.join('');
    }),
    setItem: (key: string, value: string) => serial(key, async () => {
      const previous = await readManifest(key);
      const points = Array.from(value);
      const g = generation();
      const count = Math.max(1, Math.ceil(points.length / 350));
      if (!validGeneration.test(g) || previous?.generation === g || count > MAX_CHUNKS) throw failure();
      const next = { generation: g, count };
      try {
        for (let i = 0; i < count; i++) await vault.set(chunkKey(key, g, i), points.slice(i * 350, (i + 1) * 350).join(''));
        await vault.set(manifestKey(key), JSON.stringify(next));
      } catch {
        // A vault write can fail after committing; never delete chunks if the
        // new manifest is observable or its state cannot be determined.
        try {
          const observed = await readManifest(key);
          if (observed?.generation !== g) await clean(key, next);
        } catch { /* no unsafe fallback */ }
        throw failure();
      }
      await clean(key, previous).catch(() => undefined);
    }),
    removeItem: (key: string) => serial(key, async () => {
      const m = await readManifest(key);
      // Remove the pointer before deleting chunks: partial cleanup cannot
      // restore a signed-out session.
      await vault.remove(manifestKey(key));
      await clean(key, m);
    }),
  };
}
