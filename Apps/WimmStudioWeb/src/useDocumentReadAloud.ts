import { useCallback, useEffect, useRef, useState } from 'react';
import { toVisiblePlainText } from './markdownRender';
import { runPrefetchedPlayback } from './readAloudPipeline';
import type { DocumentBlock } from './types';
import { requestZonosSpeech } from './zonosSpeech';

const MAX_CHUNK_LENGTH = 500;

function readText(block: DocumentBlock): string {
  if (block.kind.type === 'hidden' || block.markdown.startsWith('**Редакция:')) return '';
  return toVisiblePlainText(block.markdown
    .replace(/!\[[^\]]*\]\([^)]+\)/g, '')
    .replace(/^\s*(?:#{1,6}\s+|>\s*|[-*+]\s+|\d+\.\s+)/gm, ''))
    .replace(/\s+([.,:;!?])/g, '$1');
}

function* speechChunks(text: string) {
  while (text.length > MAX_CHUNK_LENGTH) {
    const wordEnd = text.lastIndexOf(' ', MAX_CHUNK_LENGTH);
    const end = wordEnd > 0 ? wordEnd : MAX_CHUNK_LENGTH;
    yield text.slice(0, end);
    text = text.slice(end).trimStart();
  }
  if (text) yield text;
}

function playAudio(blob: Blob, signal: AbortSignal): Promise<void> {
  signal.throwIfAborted();
  const url = URL.createObjectURL(blob);
  const audio = new Audio(url);
  let cancel: () => void;
  return new Promise<void>((resolve, reject) => {
    cancel = () => {
      audio.pause();
      audio.removeAttribute('src');
      resolve();
    };
    signal.addEventListener('abort', cancel, { once: true });
    audio.onended = () => resolve();
    audio.onerror = () => reject(new Error('Audio playback failed'));
    audio.play().catch(reject);
  }).finally(() => {
    signal.removeEventListener('abort', cancel);
    URL.revokeObjectURL(url);
  });
}

export function useDocumentReadAloud() {
  const run = useRef<AbortController | null>(null);
  const [blockId, setBlockId] = useState<number | null>(null);
  const [error, setError] = useState('');

  const stop = useCallback(() => {
    run.current?.abort();
    run.current = null;
    setBlockId(null);
    setError('');
  }, []);

  useEffect(() => () => run.current?.abort(), []);

  const start = async (blocks: DocumentBlock[], voice: string, fromId?: number) => {
    stop();
    const items: Array<{ blockId: number; text: string }> = [];
    for (const block of blocks) {
      if (fromId !== undefined && block.id < fromId) continue;
      const text = readText(block);
      if (!text) continue;
      for (const textChunk of speechChunks(text)) {
        items.push({ blockId: block.id, text: textChunk });
      }
    }
    if (!items.length) return;
    const abort = new AbortController();
    run.current = abort;
    setBlockId(items[0].blockId);
    try {
      await runPrefetchedPlayback({
        items,
        signal: abort.signal,
        fetchAudio: (item, signal) => requestZonosSpeech(item.text, voice, signal),
        playAudio,
        onItemStart: (item) => setBlockId(item.blockId),
      });
    } catch {
      if (!abort.signal.aborted) setError('Не удалось прочитать текст голосом ZONOS3‑Mini.');
    } finally {
      if (run.current === abort) {
        run.current = null;
        setBlockId(null);
      }
    }
  };

  return { start, stop, blockId, error };
}
