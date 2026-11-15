import fs from 'node:fs';
import http from 'node:http';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import type { IncomingMessage, ServerResponse } from 'node:http';
import { createStudioApi } from './documentApi.ts';

// Production server for the Studio web view: the built app from `dist/` plus
// the same /api/ handlers (and request guard) the Vite dev server mounts.
// Plain Node `http`, no runtime dependencies. Listens on loopback only.

export const DEFAULT_PORT = 5179;
export const HOST = '127.0.0.1';
export const DEFAULT_DIST_DIR = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', 'dist');

const MIME: Record<string, string> = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.map': 'application/json; charset=utf-8',
  '.svg': 'image/svg+xml',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.gif': 'image/gif',
  '.webp': 'image/webp',
  '.ico': 'image/x-icon',
  '.woff': 'font/woff',
  '.woff2': 'font/woff2',
  '.txt': 'text/plain; charset=utf-8',
  '.wav': 'audio/wav',
  '.mp3': 'audio/mpeg',
};

/** The real file under `distDir` for a URL path, or null when it is missing or would leave the folder. */
export function resolveStaticFile(distDir: string, urlPath: string): string | null {
  let decoded: string;
  try {
    decoded = decodeURIComponent(urlPath);
  } catch {
    return null;
  }
  if (decoded.includes('\0')) return null;
  const root = fs.realpathSync(distDir);
  const candidate = path.resolve(root, '.' + path.posix.normalize('/' + decoded));
  let real: string;
  try {
    real = fs.realpathSync(candidate);
  } catch {
    return null;
  }
  if (real !== root && !real.startsWith(root + path.sep)) return null;
  try {
    return fs.statSync(real).isFile() ? real : null;
  } catch {
    return null;
  }
}

function serveStatic(distDir: string, req: IncomingMessage, res: ServerResponse): void {
  const method = (req.method || 'GET').toUpperCase();
  if (method !== 'GET' && method !== 'HEAD') {
    res.writeHead(405, { 'Content-Type': 'text/plain; charset=utf-8', Allow: 'GET, HEAD' });
    res.end('Method not allowed');
    return;
  }
  const pathname = new URL(req.url || '/', 'http://localhost').pathname;
  let file = resolveStaticFile(distDir, pathname);
  // App routes (/dashboard, …) have no file of their own: the SPA handles them.
  if (!file && !path.posix.extname(pathname)) file = resolveStaticFile(distDir, '/index.html');
  if (!file) {
    res.writeHead(404, { 'Content-Type': 'text/plain; charset=utf-8' });
    res.end('Not found');
    return;
  }
  const ext = path.extname(file).toLowerCase();
  const hashedAsset = pathname.startsWith('/assets/');
  res.writeHead(200, {
    'Content-Type': MIME[ext] || 'application/octet-stream',
    'Content-Length': fs.statSync(file).size,
    'Cache-Control': hashedAsset ? 'public, max-age=31536000, immutable' : 'no-cache',
    'X-Content-Type-Options': 'nosniff',
  });
  if (method === 'HEAD') {
    res.end();
    return;
  }
  fs.createReadStream(file).pipe(res);
}

export interface ProdServerOptions {
  port?: number;
  distDir?: string;
}

/** Starts the server and resolves once it listens. Port 0 picks a free one (tests). */
export function startProdServer(options: ProdServerOptions = {}): Promise<http.Server> {
  const distDir = options.distDir ?? DEFAULT_DIST_DIR;
  if (!fs.existsSync(path.join(distDir, 'index.html'))) {
    return Promise.reject(
      new Error(`No built web app in ${distDir}. Run: npm ci && npm run build`)
    );
  }
  const api = createStudioApi();
  const server = http.createServer((req, res) => {
    const run = (index: number): void => {
      const middleware = api.middlewares[index];
      if (!middleware) {
        serveStatic(distDir, req, res);
        return;
      }
      Promise.resolve(middleware(req, res, () => run(index + 1))).catch((err) => {
        if (!res.headersSent) {
          res.writeHead(500, { 'Content-Type': 'application/json; charset=utf-8' });
        }
        res.end(JSON.stringify({ error: err instanceof Error ? err.message : String(err) }));
      });
    };
    run(0);
  });
  server.once('close', api.close);
  return new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(options.port ?? DEFAULT_PORT, HOST, () => {
      server.off('error', reject);
      resolve(server);
    });
  });
}
