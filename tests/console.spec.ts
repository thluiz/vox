import { test, expect } from '@playwright/test';

test('no console errors on /transcript/ page', async ({ page }) => {
  const errs: string[] = [];
  page.on('console', m => { if (m.type() === 'error') errs.push(m.text()); });
  page.on('response', r => { if (r.status() >= 400) errs.push(`${r.status()} ${r.url()}`); });
  page.on('pageerror', e => errs.push('PAGEERROR: ' + e.message + '\n' + (e.stack || '').slice(0, 600)));
  await page.goto('/transcript/?json=/2026/04/W14/303-jamil-chade.json');
  await page.waitForTimeout(1500);
  console.log('console errors:', errs);
  expect(errs).toEqual([]);
});

test('no console errors on normal episode page', async ({ page }) => {
  const errs: string[] = [];
  page.on('console', m => { if (m.type() === 'error') errs.push(m.text()); });
  page.on('response', r => { if (r.status() >= 400) errs.push(`${r.status()} ${r.url()}`); });
  page.on('pageerror', e => errs.push('PAGEERROR: ' + e.message + '\n' + (e.stack || '').slice(0, 600)));
  await page.goto('/2026/04/W14/303-jamil-chade/');
  await page.waitForTimeout(1500);
  console.log('console errors:', errs);
  expect(errs).toEqual([]);
});
