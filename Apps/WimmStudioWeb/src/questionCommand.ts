// Voice command "У меня вопрос …": a note that starts with this phrase is a
// question to the assistant, not a reply in the Angel and Demon conversation.

const QUESTION_PREFIX =
  /^[\s«"'„“(—–-]*(?:у\s+меня\s+(?:есть\s+)?|есть\s+)?вопрос(?:ы|ик)?(?![а-яё])[\s,.:;!?…—–-]*/i;

/** Returns the question without the command phrase, or null if the text is not a question command. */
export function parseQuestionCommand(text: string): string | null {
  const match = text.match(QUESTION_PREFIX);
  if (!match) return null;
  // A bare "вопрос" at the start is too common in dictation; require "у меня" / "есть".
  if (!/(?:у\s+меня|есть)/i.test(match[0])) return null;
  const question = text.slice(match[0].length).trim();
  return question.length > 0 ? question : null;
}
