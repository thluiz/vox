import { test, expect } from '@playwright/test';

// Needs a site built with the Pagefind index (hugo && npx pagefind --site public).
// `hugo server` does not produce it, so point VOX_TEST_BASE_URL at a static
// server over public/.

const PAGE = '/2026/04/W14/303-jamil-chade/';

// Desktop: search box in the navbar. Mobile: inside the hamburger sidebar.
async function openMenu(page) {
  const burger = page.locator('.hextra-hamburger-menu');
  if (await burger.isVisible()) await burger.click();
}

test('search returns results with highlighted excerpts and navigates', async ({ page }) => {
  const errs: string[] = [];
  page.on('console', m => { if (m.type() === 'error') errs.push(m.text()); });
  page.on('pageerror', e => errs.push('PAGEERROR: ' + e.message));

  await page.goto(PAGE);
  await openMenu(page);
  const input = page.locator('.hextra-search-input:visible').first();
  await input.click();
  await input.fill('jornalismo');

  const results = page.locator('.hextra-search-results:visible li a');
  await expect(results.first()).toBeVisible({ timeout: 10_000 });
  expect(await results.count()).toBeGreaterThan(1);
  await expect(page.locator('.hextra-search-excerpt mark').first()).toBeVisible();

  const href = await results.first().getAttribute('href');
  await input.press('Enter');
  await page.waitForURL(new RegExp(href!.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')));
  expect(errs).toEqual([]);
});

test('search shows a message when nothing matches', async ({ page }) => {
  await page.goto(PAGE);
  await openMenu(page);
  const input = page.locator('.hextra-search-input:visible').first();
  await input.fill('qwertyuu');
  await expect(page.locator('.hextra-search-no-result')).toBeVisible({ timeout: 10_000 });
});

test('slash shortcut focuses the search box and Escape clears it', async ({ page }) => {
  await page.goto(PAGE);
  await openMenu(page);
  const input = page.locator('.hextra-search-input:visible').first();
  await page.evaluate(() => (document.activeElement as HTMLElement)?.blur());
  await page.keyboard.press('/');
  await expect(input).toBeFocused();
  await input.fill('vox');
  await input.press('Escape');
  await expect(input).toHaveValue('');
});

test('no page downloads the legacy FlexSearch index', async ({ page }) => {
  const urls: string[] = [];
  page.on('request', r => urls.push(r.url()));
  await page.goto(PAGE);
  await openMenu(page);
  await page.locator('.hextra-search-input:visible').first().click();
  await page.waitForTimeout(500);
  expect(urls.filter(u => /search-data\.json|flexsearch/.test(u))).toEqual([]);
});

test('mobile: search works from the hamburger menu', async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 800 });
  await page.goto(PAGE);
  await page.locator('.hextra-hamburger-menu').click();
  const input = page.locator('.hextra-search-input:visible').first();
  await input.fill('jornalismo');
  await expect(page.locator('.hextra-search-results:visible li a').first()).toBeVisible({ timeout: 10_000 });
});

test('Portuguese stemming: singular and plural find the same kind of pages', async ({ page }) => {
  await page.goto(PAGE);
  const input = page.locator('.hextra-search-input:visible').first();
  const count = async (q: string) => {
    await input.fill('');
    await input.fill(q);
    const items = page.locator('.hextra-search-results:visible li a');
    await expect(items.first()).toBeVisible({ timeout: 10_000 });
    await page.waitForTimeout(400);
    return items.count();
  };
  const plural = await count('jornalistas');
  const singular = await count('jornalista');
  expect(plural).toBeGreaterThan(0);
  expect(singular).toBe(plural); // same stem => same results
});

test('searching from an English page also finds Portuguese episodes', async ({ page }) => {
  await page.goto('/2026/11/W44/heres-what-id-learn-instead-of-coding-in-2027/');
  const input = page.locator('.hextra-search-input:visible').first();
  await input.fill('jornalismo');
  await expect(page.locator('.hextra-search-results:visible li a').first()).toBeVisible({ timeout: 10_000 });
});
