# Wimm Studio web

The Studio web view: a React app (`src/`) plus a small local API (`server/`)
that reads and edits the personal document, shows sources and talks to Studio.

## Install

Dependencies are pinned by `package-lock.json`; install them with:

```bash
npm ci
```

Node 22.6 or newer is required (the server runs its TypeScript directly with
`--experimental-strip-types`, the same way `npm test` does).

## Run

- **Studio (production):** `npm run build` once (and after every web change),
  then Studio's web command starts `server/start.ts` itself: it serves `dist/`
  and the `/api/` handlers on `127.0.0.1:5179` only. To run it by hand:
  `npm start`. Studio never runs npm; if `dist/` is missing it asks you to run
  `npm ci && npm run build`.
- **Development:** `npm run dev` — the Vite dev server with hot reload, same
  API mounted as Vite middleware (`wimmStudioApiPlugin`). Stop it before
  `npm start`; both use port 5179.

Both paths share `createStudioApi()` in `server/documentApi.ts`, so every
`/api/` request passes the same guard (`server/requestGuard.ts`).

Studio finds `node` without a shell profile: `defaults write
com.micha.wimm.macos studioWebNodePath <path>`, else `/opt/homebrew/bin/node`,
`/usr/local/bin/node`, the newest `~/.nvm/versions/node/*/bin/node`,
`~/.volta/bin/node`. The project folder is `studioWebDirectory` in the same
defaults domain. Server output goes to `$TMPDIR/wimm-studio-web.log`.

Paths the API reads can be pointed at test data with `WIMM_DOC_PATH`,
`WIMM_BASE_DIR`, `WIMM_RECORDINGS_DIR`, `WIMM_READING_DIR`; the port with
`WIMM_STUDIO_WEB_PORT`.

## Test

```bash
npm test
```
