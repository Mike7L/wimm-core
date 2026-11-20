import { useEffect, useState } from 'react';

type ZonosVoice = { id: string; label: string };

export function useZonosVoices(enabled: boolean, refresh = 0) {
  const [voices, setVoices] = useState<ZonosVoice[] | null>(null);
  const [failed, setFailed] = useState(false);

  useEffect(() => {
    if (!enabled) return;
    const abort = new AbortController();
    setFailed(false);
    fetch('/api/shoulders/zonos/voices', { signal: abort.signal })
      .then(async (response) => {
        if (!response.ok) throw new Error('Voice catalog unavailable');
        const { voices } = await response.json() as { voices: ZonosVoice[] };
        if (!abort.signal.aborted) setVoices(voices);
      })
      .catch(() => {
        if (abort.signal.aborted) return;
        setVoices(null);
        setFailed(true);
      });
    return () => abort.abort();
  }, [enabled, refresh]);

  const status = failed
    ? 'Сервер ZONOS3‑Mini недоступен.'
    : voices ? 'На сервере ZONOS3‑Mini нет голосов.' : 'Загружаем голоса ZONOS3‑Mini…';
  return { voices, status };
}

export async function requestZonosSpeech(text: string, voice: string, signal?: AbortSignal): Promise<Blob> {
  const response = await fetch('/api/shoulders/zonos/speech', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ text, voice }),
    signal,
  });
  if (!response.ok) throw new Error('ZONOS3-Mini synthesis failed');
  return response.blob();
}
