// The model runs on the same machine as the Wimm web server.
const ZONOS_URL = 'http://127.0.0.1:1919';

export interface ZonosVoice {
  id: string;
  label: string;
}

export async function listZonosVoices(): Promise<ZonosVoice[]> {
  const response = await fetch(`${ZONOS_URL}/v2/speakers`, {
    redirect: 'error',
    signal: AbortSignal.timeout(3_000),
  });
  if (!response.ok) throw new Error('ZONOS3-Mini voice catalog unavailable');
  const { speakers } = await response.json() as { speakers: ZonosVoice[] };
  return speakers.map(({ id, label }) => ({ id, label }));
}

export async function synthesizeZonosWav(
  text: string,
  voice: string,
  signal: AbortSignal,
): Promise<Buffer> {
  const response = await fetch(`${ZONOS_URL}/v2/generate`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      text,
      language: 'ru',
      speaker_embedding_id: voice,
      stream: false,
      format: 'wav',
    }),
    redirect: 'error',
    signal: AbortSignal.any([signal, AbortSignal.timeout(60_000)]),
  });
  if (!response.ok || !response.headers.get('content-type')?.startsWith('audio/')) {
    throw new Error('ZONOS3-Mini synthesis failed');
  }
  return Buffer.from(await response.arrayBuffer());
}
