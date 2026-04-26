import { test, expect } from '@playwright/test';

const EP_JSON = '/2026/04/W14/303-jamil-chade.json';
const PAGE = `/transcript/?json=${EP_JSON}`;

test.describe('transcript page', () => {
  test('desktop viewport: renders title, TOC, sections; opens on click', async ({ page, browserName }) => {
    const consoleErrors: string[] = [];
    page.on('console', msg => {
      if (msg.type() === 'error') consoleErrors.push(msg.text());
    });
    page.on('pageerror', err => consoleErrors.push('PAGEERROR: ' + err.message));

    await page.goto(PAGE);

    await expect(page.locator('#tr-loader')).toBeHidden({ timeout: 10000 });

    const title = await page.locator('#tr-title').textContent();
    console.log('title:', title);
    expect(title).toContain('Jamil');

    const tocItems = await page.locator('#tr-toc li').count();
    console.log('toc items:', tocItems);
    expect(tocItems).toBeGreaterThan(3);

    const sections = await page.locator('.vox-tr-section').count();
    console.log('sections:', sections);
    expect(sections).toBe(tocItems);

    // First section should have no rendered lines before click
    const linesBefore = await page.locator('.vox-tr-section').nth(0).locator('.vox-tr-line').count();
    expect(linesBefore).toBe(0);

    // Click first section to open
    await page.locator('.vox-tr-section').nth(0).locator('summary').click();
    await page.waitForTimeout(200);

    const linesAfter = await page.locator('.vox-tr-section').nth(0).locator('.vox-tr-line').count();
    console.log('lines rendered on first section:', linesAfter);
    expect(linesAfter).toBeGreaterThan(0);

    // Close, re-open: should still have same count (no duplicate render)
    await page.locator('.vox-tr-section').nth(0).locator('summary').click();
    await page.waitForTimeout(100);
    await page.locator('.vox-tr-section').nth(0).locator('summary').click();
    await page.waitForTimeout(100);
    const linesAfter2 = await page.locator('.vox-tr-section').nth(0).locator('.vox-tr-line').count();
    expect(linesAfter2).toBe(linesAfter);

    await page.screenshot({ path: 'test-results/desktop-open.png', fullPage: false });

    // Filter out Hextra infrastructure errors unrelated to the transcript feature
    const hextraNoise = [
      'getActiveSearchElement',
      "reading 'removeAttribute'",
    ];
    const ourErrors = consoleErrors.filter(e => !hextraNoise.some(n => e.includes(n)));
    console.log('console errors (filtered):', ourErrors);
    expect(ourErrors).toEqual([]);
  });

  test('mobile viewport 375x667: renders and is usable', async ({ browser }) => {
    const ctx = await browser.newContext({ viewport: { width: 375, height: 667 } });
    const page = await ctx.newPage();
    await page.goto(PAGE);
    await expect(page.locator('#tr-loader')).toBeHidden({ timeout: 10000 });
    await expect(page.locator('#tr-toc li').first()).toBeVisible();
    await page.screenshot({ path: 'test-results/mobile-toc.png', fullPage: false });

    await page.locator('#tr-toc a').nth(2).click(); // click 3rd topic in TOC
    await page.waitForTimeout(300);
    await page.screenshot({ path: 'test-results/mobile-opened.png', fullPage: false });
    await ctx.close();
  });

  test('episode page footer exposes the reader link', async ({ page }) => {
    await page.goto('/2026/04/W14/303-jamil-chade/');
    const link = page.locator('a', { hasText: 'Ler transcrição' }).first();
    await expect(link).toBeVisible();
    const href = await link.getAttribute('href');
    console.log('reader link:', href);
    expect(href).toContain('/transcript/?json=');
    expect(href).toContain('303-jamil-chade.json');
  });

  test('missing ?json= shows error', async ({ page }) => {
    await page.goto('/transcript/');
    const text = await page.locator('#tr-loader').textContent();
    expect(text).toContain('ausente');
  });
});
