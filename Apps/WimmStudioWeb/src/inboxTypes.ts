// Shape of GET /api/inbox (server/inboxApi.ts), the web port of Studio's "Что нового".

export interface InboxSource {
  id: string;
  kind?: 'audio' | 'image' | 'text' | 'pdf' | 'unknown';
  createdAt?: string;
  durationSeconds?: number;
}

export interface InboxChange {
  blockId: number;
  kind: 'added' | 'edited';
  previous?: string;
  text: string;
  /** Read-mark key, the same as Studio's StudioInbox.hash. */
  hash: string;
  /** Level-2 section the paragraph lives in: one story ring each. */
  story: string;
  storyTitle: string;
  heading?: string;
  sectionId?: string;
  sectionHeading?: string;
  sources: InboxSource[];
}

export interface InboxQuestion {
  number: number;
  text: string;
  sources: string[];
  sourceInfo: InboxSource[];
  blockId?: number;
  storyTitle?: string;
  heading?: string;
}

export interface InboxReply {
  threadId: string;
  blockId: number | null;
  heading?: string;
  quote?: string;
  at: string;
  messages: { author: string; text: string; at: string }[];
}

export interface InboxPass {
  date: string;
  label: string;
  summary: string;
}

export interface InboxPayload {
  docModifiedAt: string;
  baseline: { kind: 'seen' | 'backup'; date: string; name: string } | null;
  changes: InboxChange[];
  questions: InboxQuestion[];
  replies: InboxReply[];
  passes: InboxPass[];
  /** Paragraphs with an open "agree" reaction in threads.jsonl (the heart). */
  liked: { blockId: number; threadId: string }[];
}
