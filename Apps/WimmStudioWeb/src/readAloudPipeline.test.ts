import { test } from 'node:test';
import assert from 'node:assert/strict';
import { runPrefetchedPlayback } from './readAloudPipeline.ts';

function deferred<T = void>() {
  let resolve!: (value: T) => void;
  let reject!: (error: unknown) => void;
  const promise = new Promise<T>((res, rej) => {
    resolve = res;
    reject = rej;
  });
  return { promise, resolve, reject };
}

test('prefetches upcoming chunks while current audio plays up to prefetchAhead', async () => {
  const events: string[] = [];
  const fetchGates = [deferred<string>(), deferred<string>(), deferred<string>(), deferred<string>()];
  const playGates = [deferred<void>(), deferred<void>(), deferred<void>(), deferred<void>()];
  const abort = new AbortController();

  const run = runPrefetchedPlayback({
    items: [0, 1, 2, 3],
    prefetchAhead: 2,
    signal: abort.signal,
    fetchAudio: async (i) => {
      events.push(`fetch:${i}`);
      return fetchGates[i].promise;
    },
    onItemStart: (i) => events.push(`start:${i}`),
    playAudio: async (audio) => {
      events.push(`play:${audio}`);
      const index = Number(audio.split(':')[1]);
      await playGates[index].promise;
    },
  });

  await Promise.resolve();
  assert.deepEqual(events, ['fetch:0']);

  fetchGates[0].resolve('audio:0');
  await new Promise((r) => setTimeout(r, 0));
  assert.deepEqual(events, ['fetch:0', 'fetch:1', 'start:0', 'play:audio:0']);

  fetchGates[1].resolve('audio:1');
  await new Promise((r) => setTimeout(r, 0));
  assert.deepEqual(events, ['fetch:0', 'fetch:1', 'start:0', 'play:audio:0', 'fetch:2']);

  // Item 3 stays queued until item 0 finishes playing.
  fetchGates[2].resolve('audio:2');
  await new Promise((r) => setTimeout(r, 0));
  assert.deepEqual(events, ['fetch:0', 'fetch:1', 'start:0', 'play:audio:0', 'fetch:2']);

  playGates[0].resolve();
  await new Promise((r) => setTimeout(r, 0));
  assert.deepEqual(events, [
    'fetch:0', 'fetch:1', 'start:0', 'play:audio:0', 'fetch:2',
    'fetch:3', 'start:1', 'play:audio:1',
  ]);

  fetchGates[3].resolve('audio:3');
  playGates[1].resolve();
  await new Promise((r) => setTimeout(r, 0));
  playGates[2].resolve();
  await new Promise((r) => setTimeout(r, 0));
  playGates[3].resolve();
  await run;

  assert.deepEqual(events.filter((e) => e.startsWith('start:')), ['start:0', 'start:1', 'start:2', 'start:3']);
});

test('plays already-fetched items before surfacing a prefetch failure', async () => {
  const played: number[] = [];
  const abort = new AbortController();

  await assert.rejects(
    runPrefetchedPlayback({
      items: [0, 1, 2],
      prefetchAhead: 2,
      signal: abort.signal,
      fetchAudio: async (i) => {
        if (i === 1) throw new Error('synthesis failed');
        return i;
      },
      playAudio: async (i) => {
        played.push(i);
      },
    }),
    /synthesis failed/,
  );

  assert.deepEqual(played, [0]);
});

test('abort stops playback and cancels in-flight prefetch', async () => {
  const abort = new AbortController();
  let fetchAborted = false;
  let playAborted = false;

  const run = runPrefetchedPlayback({
    items: [0, 1],
    signal: abort.signal,
    fetchAudio: (i, signal) => {
      if (i === 0) return Promise.resolve('audio:0');
      return new Promise((_, reject) => {
        signal.addEventListener('abort', () => {
          fetchAborted = true;
          reject(new Error('aborted'));
        }, { once: true });
      });
    },
    playAudio: (_audio, signal) => new Promise((resolve) => {
      signal.addEventListener('abort', () => {
        playAborted = true;
        resolve();
      }, { once: true });
    }),
  });

  await new Promise((r) => setTimeout(r, 0));
  abort.abort();
  await run;

  assert.equal(playAborted, true);
  assert.equal(fetchAborted, true);
});
