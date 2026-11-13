import { MicIcon } from './feedText';

export type ReplyMode = 'voice' | 'text' | 'emoji';

/** Voice is the main way to answer; text and emoji are the two round buttons beside it. */
export function ReplyActions({ onReply, voiceLabel = 'Ответить голосом', compact = false }: { onReply: (mode: ReplyMode) => void; voiceLabel?: string; /** Voice as a quiet round button too: for entries where replying is not the main action. */ compact?: boolean }) {
  return <>
    {compact
      ? <button type="button" className="chip round" onClick={() => onReply('voice')} aria-label={voiceLabel} title={voiceLabel}><MicIcon size={16} /></button>
      : <button type="button" className="chip red" onClick={() => onReply('voice')}><MicIcon size={15} />{voiceLabel}</button>}
    <button type="button" className="chip round" onClick={() => onReply('text')} aria-label="Ответить текстом" title="Ответить текстом">Аа</button>
    <button type="button" className="chip round" onClick={() => onReply('emoji')} aria-label="Ответить смайликом" title="Ответить смайликом">🙂</button>
  </>;
}
