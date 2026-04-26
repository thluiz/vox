import { test, expect } from '@playwright/test';

const PT = '/2026/04/W14/303-jamil-chade.json';
const EN = '/2026/04/W14/an-ai-state-of-the-union-weve-passed-the-inflection-point-dark-factories-are-com.json';

test('PT episode keeps Portuguese labels', async ({ page }) => {
  await page.goto(`/transcript/?json=${PT}`);
  await expect(page.locator('#tr-loader')).toBeHidden();
  await expect(page.locator('#tr-back')).toContainText('voltar ao episódio');
  await expect(page.locator('#tr-toc-nav h2')).toHaveText('Tópicos');
  await expect(page.locator('#tr-help')).toContainText('Toque num tópico');
  await expect(page).toHaveTitle(/Vox/);
  expect(await page.locator('html').getAttribute('lang')).toBe('pt');
});

test('EN episode swaps labels to English', async ({ page }) => {
  await page.goto(`/transcript/?json=${EN}`);
  await expect(page.locator('#tr-loader')).toBeHidden();
  await expect(page.locator('#tr-back')).toContainText('back to episode');
  await expect(page.locator('#tr-toc-nav h2')).toHaveText('Topics');
  await expect(page.locator('#tr-help')).toContainText('Tap a topic');
  await expect(page.locator('#tr-title')).toContainText('Transcript');
  expect(await page.locator('html').getAttribute('lang')).toBe('en');
});
