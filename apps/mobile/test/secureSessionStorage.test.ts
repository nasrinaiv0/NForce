import { describe, expect, it } from 'vitest';
import { createSecureSessionStorage } from '@/data/secureSessionStorage';

function fixture() {
  const items = new Map<string, string>();
  const legacy: string[] = [];
  let seq = 0;
  let failWrite = false;
  const storage = createSecureSessionStorage({
    get: async (key) => items.get(key) ?? null,
    set: async (key, value) => {
      if (failWrite && key.endsWith('.1')) throw new Error('vault write error');
      items.set(key, value);
    },
    remove: async (key) => { items.delete(key); },
  }, () => 'g-' + ++seq, async (key) => { legacy.push(key); });
  return { storage, items, legacy, fail: () => { failWrite = true; } };
}

describe('native secure session adapter', () => {
  it('round trips large unicode sessions in bounded chunks and deletes legacy keys', async () => {
    const f = fixture();
    const session = '🔐'.repeat(1100) + 'fictional';
    await f.storage.setItem('sb-test-auth-token', session);
    expect(await f.storage.getItem('sb-test-auth-token')).toBe(session);
    expect(f.legacy).toEqual(['sb-test-auth-token', 'sb-test-auth-token']);
    expect([...f.items.keys()].every((k) => k.startsWith('nforce.v1.'))).toBe(true);
    await f.storage.removeItem('sb-test-auth-token');
    expect(await f.storage.getItem('sb-test-auth-token')).toBeNull();
    expect(f.items.size).toBe(0);
  });
  it('retains previous manifest on interrupted chunk write, without insecure fallback', async () => {
    const f = fixture();
    await f.storage.setItem('session', 'original');
    f.fail();
    await expect(f.storage.setItem('session', 'x'.repeat(1000))).rejects.toThrow('Secure session storage unavailable');
    expect(await f.storage.getItem('session')).toBe('original');
  });
  it('fails closed on missing chunks and invalid keys', async () => {
    const f = fixture();
    await f.storage.setItem('session', 'hello');
    f.items.delete('nforce.v1.session.g-1.0');
    await expect(f.storage.getItem('session')).rejects.toThrow('Secure session storage unavailable');
    await expect(f.storage.setItem('../invalid', 'secret')).rejects.toThrow('Secure session storage unavailable');
  });
  it('serializes refresh and logout', async () => {
    const f = fixture();
    await Promise.all([f.storage.setItem('session', 'one'), f.storage.setItem('session', 'two'), f.storage.removeItem('session')]);
    expect(await f.storage.getItem('session')).toBeNull();
    expect(f.items.size).toBe(0);
  });
});
