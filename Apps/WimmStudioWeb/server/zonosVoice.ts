import { spawn, type ChildProcess } from 'node:child_process';
import { randomBytes } from 'node:crypto';
import { existsSync } from 'node:fs';
import path from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';
import { fileURLToPath } from 'node:url';

const ZONOS_URL = 'http://127.0.0.1:1919';
const runtime = fileURLToPath(new URL('../.cache/zonos3/', import.meta.url));

export interface ZonosVoice {
  id: string;
  label: string;
}

export function createZonosVoice() {
  let managed: { child: ChildProcess; token: string } | null = null;
  let starting: Promise<void> | null = null;
  let closed = false;

  const request = (route: string, options: RequestInit) => {
    const headers = new Headers(options.headers);
    if (managed) headers.set('Authorization', `Bearer ${managed.token}`);
    return fetch(`${ZONOS_URL}${route}`, { ...options, headers, redirect: 'error' });
  };

  const catalog = async () => {
    const response = await request('/v2/speakers', { signal: AbortSignal.timeout(3_000) });
    if (!response.ok) throw new Error(`ZONOS3-Mini catalog returned HTTP ${response.status}`);
    const { speakers } = await response.json() as { speakers: ZonosVoice[] };
    return speakers.map(({ id, label }) => ({ id, label }));
  };

  const start = async () => {
    if (closed || !existsSync(path.join(runtime, '.wimm-ready'))) {
      throw new Error('ZONOS3-Mini runtime unavailable');
    }
    const models = path.join(runtime, 'servers/ggml/gguf');
    const token = randomBytes(24).toString('hex');
    const child = spawn(path.join(runtime, '.venv/bin/python'), [
      '-m', 'zonos3_mlx', path.join(models, 'backbone-ptq.gguf'),
      '--host', '127.0.0.1', '--port', '1919',
      '--tts-default-voices-dir', path.join(models, 'voices'),
    ], {
      cwd: runtime,
      env: { ...process.env, ZONOS3_ACCESS_TOKEN: token, HF_HUB_OFFLINE: '1' },
      stdio: 'ignore',
    });
    managed = { child, token };
    const clear = () => {
      if (managed?.child === child) managed = null;
    };
    child.once('error', clear);
    child.once('exit', clear);
    try {
      const deadline = Date.now() + 45_000;
      while (managed?.child === child && Date.now() < deadline) {
        await delay(250);
        if (managed?.child !== child) break;
        try {
          await catalog();
          return;
        } catch {
          // MLX opens the port once the models are loaded.
        }
      }
      throw new Error('ZONOS3-Mini failed to start');
    } catch (error) {
      child.kill();
      clear();
      throw error;
    }
  };

  const listVoices = async () => {
    if (!starting) {
      try {
        return await catalog();
      } catch (error) {
        if (!starting && !managed) {
          // An existing compatible server takes precedence over our managed runtime.
          if (!(error instanceof TypeError) ||
              (error.cause as NodeJS.ErrnoException | undefined)?.code !== 'ECONNREFUSED') throw error;
          starting = start().finally(() => { starting = null; });
        }
      }
    }
    await starting;
    return catalog();
  };

  return {
    listVoices,
    async synthesize(text: string, voice: string, signal: AbortSignal): Promise<Buffer> {
      if (starting || !managed) await listVoices();
      signal.throwIfAborted();
      const response = await request('/v2/generate', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          text,
          language: 'ru',
          speaker_embedding_id: voice,
          stream: false,
          format: 'wav',
        }),
        signal: AbortSignal.any([signal, AbortSignal.timeout(60_000)]),
      });
      if (!response.ok || !response.headers.get('content-type')?.startsWith('audio/')) {
        throw new Error(`ZONOS3-Mini synthesis returned HTTP ${response.status}`);
      }
      return Buffer.from(await response.arrayBuffer());
    },
    close() {
      closed = true;
      managed?.child.kill();
      managed = null;
    },
  };
}
