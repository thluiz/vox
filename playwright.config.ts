import { defineConfig, devices } from '@playwright/test';

const baseURL = process.env.VOX_TEST_BASE_URL || 'http://localhost:1313';

export default defineConfig({
  testDir: './tests',
  fullyParallel: true,
  reporter: 'list',
  use: {
    baseURL,
    trace: 'retain-on-failure',
  },
  projects: [
    { name: 'chromium', use: { ...devices['Desktop Chrome'] } },
  ],
});
