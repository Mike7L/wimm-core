export type BlockKind =
  | { type: 'heading'; level: number }
  | { type: 'body' }
  | { type: 'hidden' };

export interface CitedImage {
  sourceId: string;
  path: string;
}

/** Capture dates (YYYY-MM-DD) of the sources a block cites; for a heading, of its whole topic. */
export interface SourceDateRange {
  /** `from`/`to` are empty when every cited source came with a bulk import. */
  from: string;
  to: string;
  /** Cited sources with a known date. */
  dated: number;
  /** Cited sources without one (wiki pages). */
  undated: number;
  /** Cited sources from a bulk import day: their date is the import's, so it is not shown. */
  imported: number;
}

export interface DocumentBlock {
  id: number;
  kind: BlockKind;
  markdown: string;
  anchor?: string;
  sectionId?: string;
  sectionHeading?: string;
  sources: string[];
  citedImages?: CitedImage[];
  sourceDates?: SourceDateRange;
  startOffset: number;
  endOffset: number;
}

export type CommentStatus = 'open' | 'answered' | 'applied' | 'resolved' | 'dropped';

export interface CommentRecord {
  id: string;
  kind: 'comment' | 'reaction' | 'reply' | 'status';
  doc: string;
  author: string;
  at: string;
  text?: string;
  section?: string;
  heading?: string;
  quote?: string;
  prefix?: string;
  suffix?: string;
  reaction?: string;
  intent?: string;
  reply_to?: string;
  status?: CommentStatus;
  via?: string;
}

export interface CommentThread {
  id: string;
  root: CommentRecord;
  replies: CommentRecord[];
  status: CommentStatus;
  blockId: number | null;
  exactMatch: boolean;
  lastActivityAt?: string;
}

export interface DocumentPayload {
  /** 'main' or the id of a read-only reading text. */
  docId: string;
  readOnly: boolean;
  documents: Array<{ id: string; label: string }>;
  filePath: string;
  docRelPath: string;
  threadsPath: string;
  sha256: string;
  modifiedAt: string;
  blocks: DocumentBlock[];
  threads: CommentThread[];
  sourceCount: number;
}

export interface SourceDetail {
  sourceId: string;
  status?: string;
  reason?: string;
  reviewedOn?: string;
  metaPath?: string;
  recordingPath?: string;
  audioPaths?: string[];
  documentPaths?: string[];
  imagePaths?: string[];
  mediaKind?: 'audio' | 'image' | 'text' | 'pdf' | 'unknown';
  createdAt?: string;
  durationSeconds?: number;
  primaryText?: string;
  liveTranscript?: string;
  attachmentText?: string;
  previousRuns?: Array<{
    provider?: string;
    model?: string;
    timestamp?: string;
    transcript?: string;
  }>;
}

export interface ReactionPreset {
  intent: string;
  emoji: string;
  label: string;
  instruction: string;
}

export const REACTION_PRESETS: ReactionPreset[] = [
  {
    intent: 'agree',
    emoji: '👍',
    label: 'Точно',
    instruction: 'Owner confirms this text is correct; keep it as is.',
  },
  {
    intent: 'wrong',
    emoji: '❌',
    label: 'Неверно',
    instruction: 'Owner says this is wrong; ask what is right or fix it from the sources.',
  },
  {
    intent: 'unclear',
    emoji: '❓',
    label: 'Непонятно',
    instruction: 'Owner does not understand this; rewrite it more plainly or explain.',
  },
  {
    intent: 'expand',
    emoji: '💡',
    label: 'Развернуть',
    instruction: 'Owner wants more here; elaborate from the sources or ask.',
  },
  {
    intent: 'trim',
    emoji: '✂️',
    label: 'Сократить',
    instruction: 'Owner finds this unneeded; shorten or remove it.',
  },
  {
    intent: 'important',
    emoji: '⭐',
    label: 'Важно',
    instruction: 'Owner marks this as important; keep it prominent.',
  },
];

export type ShouldersStyleId = 'original' | 'ownVoices' | 'listening';
export type ShouldersThinkingId = 'none' | 'low' | 'medium' | 'default';
/** Where a turn takes its dossier: the generated retelling, or sections of the document itself. */
export type ShouldersDossierSource = 'file' | 'document';
export type ShoulderSpeaker = 'angel' | 'demon';

export interface ShoulderLine {
  speaker: ShoulderSpeaker;
  text: string;
}

export interface ShouldersMessage {
  role: 'user' | 'model';
  text: string;
  lines?: ShoulderLine[];
  at?: string;
  viaVoiceNote?: string;
  noteFile?: string;
}

export interface LatestVoiceNote {
  noteId: string;
  fileName: string;
  timestamp?: string;
  durationSeconds?: number;
  text: string;
  isLiveOnly?: boolean;
  conversationFile?: string;
  originSection?: string;
  originHeading?: string;
}

export interface ActiveRecordingInfo {
  fileName: string;
  noteId: string;
  startedAt: string;
}

export interface ShouldersStatus {
  ready: boolean;
  privateMode: boolean;
  hasApiKey: boolean;
  hasDossier: boolean;
  dossierPath: string;
  dossierUpdatedAt?: string;
  dossierWordCount?: number;
  dossierKey?: string;
  documentDossierWordCount?: number;
  documentDossierUpdatedAt?: string;
  model: string;
  defaultStyle: ShouldersStyleId;
  defaultThinking: ShouldersThinkingId;
  latestNote?: LatestVoiceNote | null;
  activeRecording?: ActiveRecordingInfo | null;
  error?: string;
}

