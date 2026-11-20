// JavaScript port of WimmDomain/Notes/NoteContent.swift.
const types = {
  audio: 'm4a mp3 wav aiff aif caf flac aac opus oga ogg',
  text: 'txt md markdown',
  image: 'heic heif png jpg jpeg gif tiff webp bmp',
  pdf: 'pdf',
};
const kinds = new Map(Object.entries(types).flatMap(([kind, extensions]) =>
  extensions.split(' ').map(extension => [extension, kind])));

export function extension(name) {
  return /\.([^.\/]+)$/.exec(name)?.[1].toLowerCase() ?? '';
}

export function noteKind(name) {
  return kinds.get(extension(name)) ?? 'document';
}

export function clean(value) {
  return typeof value === 'string' && value.trim() ? value.trim() : null;
}

export function resolveContent(name, metadata = {}, fileText = null) {
  const kind = noteKind(name);
  const documentText = clean(metadata.document?.text);
  let body = null;
  let bodySource = null;
  if (kind === 'text') {
    body = fileText === null ? documentText : clean(fileText);
    if (body) bodySource = fileText === null ? 'documentText' : 'typedFile';
  } else if ((body = clean(metadata.transcription?.transcript))) {
    bodySource = 'transcript';
  } else if ((body = clean(metadata.transcription))) {
    bodySource = 'legacyTranscript';
  } else if (kind !== 'audio' && documentText) {
    body = documentText;
    bodySource = 'documentText';
  }
  return { kind, body, bodySource, fileText: kind === 'text' ? fileText : null,
    fileUnreadable: kind === 'text' && fileText === null };
}
