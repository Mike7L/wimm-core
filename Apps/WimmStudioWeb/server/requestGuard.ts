import fs from 'node:fs';
import path from 'node:path';
import type { IncomingHttpHeaders } from 'node:http';

// The Studio web server runs on the user's Mac and edits the personal
// document, starts recordings and makes paid model calls. Any web page open
// in a browser can send it a blind POST, so every /api/ request passes here
// first.

const LOOPBACK_HOSTS = new Set(['localhost', '127.0.0.1', '[::1]']);

export interface ApiRequestLike {
  method?: string;
  headers: IncomingHttpHeaders;
}

export interface Rejection {
  status: number;
  message: string;
}

function firstHeader(value: string | string[] | undefined): string | undefined {
  return Array.isArray(value) ? value[0] : value;
}

/** True when `origin` is this server itself: http on a loopback name and the port the request came in on. */
export function isOwnOrigin(origin: string, localPort: number | undefined): boolean {
  if (localPort === undefined) return false;
  let parsed: URL;
  try {
    parsed = new URL(origin);
  } catch {
    return false;
  }
  if (parsed.protocol !== 'http:') return false;
  if (!LOOPBACK_HOSTS.has(parsed.hostname)) return false;
  const port = parsed.port ? Number(parsed.port) : 80;
  return port === localPort;
}

/** A Host header naming anything but loopback means DNS rebinding or a proxy we did not set up. */
function isLoopbackHost(host: string | undefined): boolean {
  if (!host) return true;
  try {
    return LOOPBACK_HOSTS.has(new URL(`http://${host}`).hostname);
  } catch {
    return false;
  }
}

/**
 * Returns why an /api/ request must be refused, or null to let it through.
 * - an `Origin` header must be this server's own origin (a missing one is a
 *   same-origin GET or a non-browser client);
 * - the `Host` must be loopback;
 * - every non-GET/HEAD request must carry `Content-Type: application/json`,
 *   which a page on another site cannot send without a CORS preflight.
 */
export function apiRequestRejection(req: ApiRequestLike, localPort: number | undefined): Rejection | null {
  const origin = firstHeader(req.headers.origin);
  if (origin !== undefined && !isOwnOrigin(origin, localPort)) {
    return { status: 403, message: 'Cross-origin request refused' };
  }
  if (!isLoopbackHost(firstHeader(req.headers.host))) {
    return { status: 403, message: 'Host not allowed' };
  }
  const method = (req.method || 'GET').toUpperCase();
  if (method !== 'GET' && method !== 'HEAD') {
    const contentType = firstHeader(req.headers['content-type']) || '';
    const mediaType = contentType.split(';')[0].trim().toLowerCase();
    if (mediaType !== 'application/json') {
      return { status: 415, message: 'Content-Type must be application/json' };
    }
  }
  return null;
}

/**
 * Resolves a requested media path through symlinks and returns it only if the
 * real file lies inside one of the real allowed directories. Returns null for
 * a missing file or one outside them.
 */
export function resolveAllowedMediaPath(requested: string, allowedDirs: string[]): string | null {
  let real: string;
  try {
    real = fs.realpathSync(path.resolve(requested));
  } catch {
    return null;
  }
  for (const dir of allowedDirs) {
    let realDir: string;
    try {
      realDir = fs.realpathSync(path.resolve(dir));
    } catch {
      continue;
    }
    if (real.startsWith(realDir + path.sep)) return real;
  }
  return null;
}

export type BlockHashCheck = { ok: true } | { ok: false; status: number; message: string };

/** `/api/block` writes only over the exact version the editor opened. */
export function checkExpectedSha256(expected: unknown, currentHash: string): BlockHashCheck {
  if (typeof expected !== 'string' || !expected) {
    return {
      ok: false,
      status: 400,
      message: 'Нет отпечатка версии документа (expectedSha256). Откройте абзац заново.',
    };
  }
  if (expected !== currentHash) {
    return {
      ok: false,
      status: 409,
      message: 'Документ изменился после начала редактирования. Скопируйте черновик и откройте абзац заново.',
    };
  }
  return { ok: true };
}
