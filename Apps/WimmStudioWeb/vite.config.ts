import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';
import tailwindcss from '@tailwindcss/vite';
import { wimmStudioApiPlugin } from './server/documentApi';

export default defineConfig({
  plugins: [react(), tailwindcss(), wimmStudioApiPlugin()],
  server: {
    port: 5179,
    strictPort: false,
  },
});
