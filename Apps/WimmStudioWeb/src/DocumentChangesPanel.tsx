import { useEffect, useState } from 'react';
import type { DocumentChanges } from './documentChanges';

export function DocumentChangesPanel({ revision }: { revision?: string }) {
  const [baseline, setBaseline] = useState('');
  const [data, setData] = useState<DocumentChanges | null>(null);
  const [error, setError] = useState('');
  const [loading, setLoading] = useState(true);
  useEffect(() => {
    const controller = new AbortController();
    setLoading(true);
    setError('');
    fetch(`/api/document/changes${baseline ? `?baseline=${encodeURIComponent(baseline)}` : ''}`, {
      signal: controller.signal, cache: 'no-store',
    }).then(async res => {
      if (!res.ok) throw new Error(await res.text());
      return res.json() as Promise<DocumentChanges>;
    }).then(result => {
      if (!controller.signal.aborted) setData(result);
    }).catch(err => {
      if (!controller.signal.aborted) setError(err.message || 'Не удалось загрузить правки');
    }).finally(() => {
      if (!controller.signal.aborted) setLoading(false);
    });
    return () => controller.abort();
  }, [baseline, revision]);

  return (
    <section aria-label="Правки документа" className="mx-auto max-w-5xl space-y-3 text-xs">
      <div className="flex flex-wrap items-center gap-3">
        <h1 className="text-sm font-semibold text-zinc-100">Правки <span className="ml-1 text-[10px] font-normal text-zinc-400">эксперимент</span></h1>
        {data && data.backups.length > 0 && (
          <label className="flex min-w-0 items-center gap-2 text-zinc-400">
            <span className="shrink-0">С копии перед запуском</span>
            <select aria-label="Копия для сравнения" value={baseline || data.baseline || ''}
              onChange={e => setBaseline(e.target.value)}
              className="min-w-0 max-w-sm rounded border border-zinc-700 bg-zinc-900 px-2 py-1 text-zinc-200">
              {data.backups.map(b => <option key={b.id} value={b.id}>{new Date(b.date).toLocaleString('ru-RU')}</option>)}
            </select>
          </label>
        )}
        {data && !loading && !error && <span className="ml-auto flex gap-3 font-mono">
          <span className="text-emerald-300">+{data.added} строк</span>
          <span className="text-rose-300">−{data.removed} строк</span>
        </span>}
      </div>
      <p className="text-zinc-400">Сравнение с текущим документом, включая ручные правки. Неизменённые части скрыты; рядом с правками — две строки контекста.</p>
      <div role="status" aria-live="polite" className="text-zinc-400">
        {loading ? 'Сравниваем версии…' : error ? <span className="text-rose-300">{error}</span> :
          !data?.baseline ? 'Копий перед запуском секретаря пока нет.' :
          !data.hunks.length ? 'Документ не изменился с выбранной копии.' : `${data.hunks.length} фрагментов с правками`}
      </div>
      {!loading && !error && data?.hunks.map((hunk, index) => {
        let oldLine = hunk.oldLine;
        let newLine = hunk.newLine;
        return <details key={`${data.baseline}-${index}`} open className="overflow-hidden rounded-lg border border-zinc-800 bg-zinc-950/60">
          <summary className="cursor-pointer bg-zinc-900/80 px-3 py-1.5 font-mono text-[11px] text-zinc-400">
            Фрагмент {index + 1} · строки {hunk.oldLine} → {hunk.newLine}
          </summary>
          <div className="py-1 font-mono text-[12px] leading-5">
            {hunk.lines.map((line, i) => {
              const old = line.kind === 'added' ? '' : oldLine++;
              const next = line.kind === 'removed' ? '' : newLine++;
              return <div key={i} className={`flex ${line.kind === 'added' ? 'bg-emerald-500/10 text-emerald-200' : line.kind === 'removed' ? 'bg-rose-500/10 text-rose-200' : 'text-zinc-500'}`}>
                <span aria-hidden="true" className="w-10 shrink-0 select-none pr-1 text-right text-[10px] opacity-60">{old}</span>
                <span aria-hidden="true" className="w-10 shrink-0 select-none pr-2 text-right text-[10px] opacity-60">{next}</span>
                <span className="w-5 shrink-0 select-none text-center">{line.kind === 'added' ? '+' : line.kind === 'removed' ? '−' : ' '}</span>
                <span className="min-w-0 flex-1 whitespace-pre-wrap break-words pr-3">{line.text || '\u00a0'}</span>
              </div>;
            })}
          </div>
        </details>;
      })}
    </section>
  );
}
