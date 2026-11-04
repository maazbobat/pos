import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    // All files share one emulator, so run them one at a time.
    fileParallelism: false,
    testTimeout: 30_000,
    hookTimeout: 60_000,
  },
});
