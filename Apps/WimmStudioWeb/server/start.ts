import { DEFAULT_PORT, HOST, startProdServer } from './prodServer.ts';

// `npm start`: serves the built app from dist/ on 127.0.0.1:5179.
// Studio's web launcher runs this file directly with node.

const port = Number(process.env.WIMM_STUDIO_WEB_PORT) || DEFAULT_PORT;

startProdServer({ port }).then(
  (server) => {
    console.log(`Wimm Studio web: http://${HOST}:${port}/`);
    const stop = () => {
      server.close(() => process.exit(0));
      server.closeAllConnections(); // open event streams would hold close() forever
    };
    process.on('SIGTERM', stop);
    process.on('SIGINT', stop);
  },
  (err) => {
    console.error(err instanceof Error ? err.message : String(err));
    process.exit(1);
  }
);
