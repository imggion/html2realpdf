import { defineConfig, devices } from "@playwright/test";

export default defineConfig({
  testDir: "./e2e",
  outputDir: "../../tmp/playwright-results",
  timeout: 120_000,
  expect: { timeout: 30_000 },
  fullyParallel: false,
  workers: 1,
  reporter: [["line"]],
  use: {
    baseURL: "http://127.0.0.1:4173",
    trace: "retain-on-failure",
    screenshot: "only-on-failure",
  },
  webServer: [
    {
      command: "python3 -m http.server 4173 --bind 127.0.0.1",
      cwd: "../..",
      url: "http://127.0.0.1:4173/tests/web/index.html",
      reuseExistingServer: true,
      timeout: 30_000,
    },
    {
      command: "npm run preview -- --host 127.0.0.1 --port 4174 --strictPort",
      cwd: "../react",
      url: "http://127.0.0.1:4174",
      reuseExistingServer: true,
      timeout: 30_000,
    },
  ],
  projects: [
    { name: "chromium", use: { ...devices["Desktop Chrome"] } },
    { name: "firefox", use: { ...devices["Desktop Firefox"] } },
    { name: "webkit", use: { ...devices["Desktop Safari"] } },
  ],
});
