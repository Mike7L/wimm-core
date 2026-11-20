export interface PrefetchPlaybackOptions<T, A> {
  items: ReadonlyArray<T>;
  prefetchAhead?: number;
  signal: AbortSignal;
  fetchAudio: (item: T, signal: AbortSignal) => Promise<A>;
  playAudio: (audio: A, signal: AbortSignal) => Promise<void>;
  onItemStart?: (item: T) => void;
}

/**
 * Synthesizes upcoming chunks sequentially in the background while the current
 * audio plays, keeping at most `prefetchAhead` buffered items ahead so there
 * is no silence gap between paragraphs without flooding the single-worker TTS server.
 */
export async function runPrefetchedPlayback<T, A>({
  items,
  prefetchAhead = 2,
  signal,
  fetchAudio,
  playAudio,
  onItemStart,
}: PrefetchPlaybackOptions<T, A>): Promise<void> {
  if (!items.length || signal.aborted) return;

  const runAbort = new AbortController();
  const onExternalAbort = () => runAbort.abort();
  signal.addEventListener('abort', onExternalAbort, { once: true });

  const slots = items.map(() => {
    let resolve!: (audio: A) => void;
    let reject!: (error: unknown) => void;
    const promise = new Promise<A>((res, rej) => {
      resolve = res;
      reject = rej;
    });
    // Playback awaits slots in order; prevent unhandled rejections if prefetch fails early.
    promise.catch(() => {});
    return { promise, resolve, reject };
  });

  let playingIndex = 0;
  let wakePrefetch: (() => void) | null = null;
  const notifyPrefetch = () => {
    wakePrefetch?.();
    wakePrefetch = null;
  };
  runAbort.signal.addEventListener('abort', notifyPrefetch, { once: true });

  const prefetcher = (async () => {
    for (let i = 0; i < items.length; i++) {
      while (!runAbort.signal.aborted && i > playingIndex + prefetchAhead) {
        await new Promise<void>((resolve) => {
          wakePrefetch = resolve;
        });
      }
      if (runAbort.signal.aborted) break;
      try {
        const audio = await fetchAudio(items[i], runAbort.signal);
        slots[i].resolve(audio);
      } catch (error) {
        for (let j = i; j < items.length; j++) slots[j].reject(error);
        break;
      }
    }
  })();

  try {
    for (let i = 0; i < items.length; i++) {
      playingIndex = i;
      notifyPrefetch();
      const audio = await slots[i].promise;
      if (runAbort.signal.aborted) return;
      onItemStart?.(items[i]);
      await playAudio(audio, runAbort.signal);
      if (runAbort.signal.aborted) return;
    }
  } finally {
    runAbort.abort();
    signal.removeEventListener('abort', onExternalAbort);
    notifyPrefetch();
    await prefetcher;
  }
}
