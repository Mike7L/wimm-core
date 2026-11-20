/**
 * Parse a Markdown link/citation reference definition line (`[id]: target`).
 * Shared between document block parsing (`hidden` blocks) and dossier cleaning
 * so both classify the exact same lines as link definitions.
 */
export function parseReferenceDefinition(rawLine: string): { id: string; target: string } | null {
  const match = /^\[([^\]]+)\]:\s*(\S+)/.exec(rawLine.trim());
  if (!match) return null;
  return { id: match[1], target: match[2] };
}
