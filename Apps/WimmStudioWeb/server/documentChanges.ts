import fs from 'node:fs';
import path from 'node:path';
import { spawn } from 'node:child_process';
import type { DocumentChanges, DiffHunk } from '../src/documentChanges';

export async function documentChanges(docPath: string, selected: string | null): Promise<DocumentChanges> {
  const folder = path.join(path.dirname(docPath), '.backups');
  const stem = path.basename(docPath, path.extname(docPath));
  const backups = (fs.existsSync(folder) ? fs.readdirSync(folder) : [])
    .filter(name => name.startsWith(`${stem}.`) && name.includes('before-secretary') && !name.includes('.sources.'))
    .flatMap(name => {
      const file = path.join(folder, name);
      const stat = fs.lstatSync(file);
      if (!stat.isFile()) return [];
      const modern = name.match(/(\d{4})-(\d{2})-(\d{2})-(\d{2})(\d{2})(\d{2})/);
      const legacy = name.match(/(\d{4})(\d{2})(\d{2})-(?:[a-z]+-)*(\d{2})(\d{2})(?!\d)/);
      const stamp = modern || legacy;
      const date = stamp ? new Date(`${stamp[1]}-${stamp[2]}-${stamp[3]}T${stamp[4]}:${stamp[5]}:${stamp[6] || '00'}`) : stat.mtime;
      return [{ id: name, date: Number.isNaN(date.getTime()) ? stat.mtime.toISOString() : date.toISOString() }];
    })
    .sort((a, b) => b.date.localeCompare(a.date) || b.id.localeCompare(a.id));
  const baseline = selected === null ? backups[0]?.id ?? null : selected;
  if (baseline !== null && !backups.some(b => b.id === baseline)) throw new Error('Копия для сравнения не найдена');
  if (!baseline) return { backups, baseline, hunks: [], added: 0, removed: 0 };
  const current = fs.readFileSync(docPath, 'utf8');
  const output = await new Promise<string>((resolve, reject) => {
    const child = spawn('/usr/bin/diff', ['-U', '2', path.join(folder, baseline), '-']);
    const chunks: Buffer[] = [];
    let size = 0;
    const timeout = setTimeout(() => child.kill(), 10_000);
    child.stdout.on('data', (chunk: Buffer) => {
      size += chunk.length;
      if (size > 16 * 1024 * 1024) child.kill();
      else chunks.push(chunk);
    });
    child.stdin.on('error', () => { /* exit handler reports diff failure */ });
    child.on('error', reject);
    child.on('close', code => {
      clearTimeout(timeout);
      if (code === 0 || code === 1) resolve(Buffer.concat(chunks).toString('utf8'));
      else reject(new Error('Не удалось сравнить версии документа'));
    });
    child.stdin.end(current);
  });
  const hunks: DiffHunk[] = [];
  let added = 0;
  let removed = 0;
  for (const line of output.split('\n')) {
    const header = line.match(/^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@/);
    if (header) {
      hunks.push({ oldLine: Number(header[1]), newLine: Number(header[2]), lines: [] });
      continue;
    }
    const hunk = hunks.at(-1);
    if (!hunk || !['+', '-', ' '].includes(line[0])) continue;
    const kind = line[0] === '+' ? 'added' : line[0] === '-' ? 'removed' : 'context';
    if (kind === 'added') added++;
    if (kind === 'removed') removed++;
    hunk.lines.push({ kind, text: line.slice(1) });
  }
  return { backups, baseline, hunks, added, removed };
}
