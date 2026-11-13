export interface DiffHunk {
  oldLine: number;
  newLine: number;
  lines: { kind: 'added' | 'removed' | 'context'; text: string }[];
}

export interface DocumentChanges {
  backups: { id: string; date: string }[];
  baseline: string | null;
  hunks: DiffHunk[];
  added: number;
  removed: number;
}
