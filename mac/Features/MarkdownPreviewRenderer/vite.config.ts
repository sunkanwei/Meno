import { defineConfig } from 'vite';

export default defineConfig({
  base: './',
  build: {
    modulePreload: false,
    outDir: 'dist',
    assetsDir: 'assets',
    sourcemap: false,
    emptyOutDir: true,
    rollupOptions: {
      treeshake: {
        moduleSideEffects: false,
      },
      input: 'index.html',
    },
    chunkSizeWarningLimit: 2200,
  },
  test: {
    environment: 'jsdom',
    include: ['src/__tests__/**/*.test.ts'],
  },
});
