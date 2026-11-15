import { test, expect } from '@playwright/test';

// /podcasts/ — taxonomia "podcast" (campo `podcast:` do frontmatter).

test.describe('podcasts page', () => {
  test('lists podcasts by episode count, no console errors', async ({ page }) => {
    const errs: string[] = [];
    page.on('console', m => { if (m.type() === 'error') errs.push(m.text()); });
    page.on('response', r => { if (r.status() >= 400) errs.push(`${r.status()} ${r.url()}`); });
    page.on('pageerror', e => errs.push('PAGEERROR: ' + e.message));
    await page.goto('/podcasts/');
    await page.evaluate(() => localStorage.removeItem('vox-podcasts-sort'));
    await page.reload();

    await expect(page.locator('h1')).toHaveText('Podcasts');
    const counts = await page.locator('[data-podcasts-list] >> nth=0').locator('li')
      .evaluateAll(lis => lis.map(li => Number((li as HTMLElement).dataset.count)));
    expect(counts.length).toBeGreaterThan(10);
    expect(counts).toEqual([...counts].sort((a, b) => b - a));
    // podcasts de 1 episódio ficam recolhidos
    await expect(page.locator('details.vox-podcasts-single')).not.toHaveAttribute('open', '');
    await page.waitForTimeout(500);
    expect(errs).toEqual([]);
  });

  test('every podcast URL is a Windows-safe slug ([a-z0-9-])', async ({ page }) => {
    // O termo vira pasta no build (Windows). Slug fora disso = podcast_slug
    // não veio do Toscanini.PodcastSlug — ver hugo.toml.
    await page.goto('/podcasts/');
    const hrefs = await page.locator('[data-podcasts-list] li a')
      .evaluateAll(as => as.map(a => a.getAttribute('href') || ''));
    expect(hrefs.length).toBeGreaterThan(100);
    const bad = hrefs.filter(h => !/^\/podcasts\/[a-z0-9]+(-[a-z0-9]+)*\/$/.test(h));
    expect(bad).toEqual([]);
  });

  test('A–Z sorts with Portuguese collation and persists', async ({ page }) => {
    await page.goto('/podcasts/');
    await page.getByRole('button', { name: 'A–Z' }).click();
    await expect(page.getByRole('button', { name: 'A–Z' })).toHaveAttribute('aria-pressed', 'true');

    const names = await page.locator('[data-podcasts-list] >> nth=0').locator('li')
      .evaluateAll(lis => lis.map(li => (li as HTMLElement).dataset.name || ''));
    const strip = (s: string) => s.replace(/^[^\p{L}\p{N}]+/u, '');
    const collator = new Intl.Collator('pt', { sensitivity: 'base', numeric: true });
    expect(names).toEqual([...names].sort((a, b) => collator.compare(strip(a), strip(b))));

    await page.reload();
    await expect(page.getByRole('button', { name: 'A–Z' })).toHaveAttribute('aria-pressed', 'true');
  });

  test('episode footer links to its podcast page', async ({ page }) => {
    await page.goto('/2026/04/W14/303-jamil-chade/');
    const link = page.locator('.vox-footer-identity strong a');
    const name = (await link.textContent())?.trim() || '';
    expect(await link.getAttribute('href')).toMatch(/^\/podcasts\/.+\/$/);
    await link.click();
    await expect(page.locator('h1')).toContainText(name);
    await expect(page.getByRole('link', { name: '← Todos os podcasts' })).toBeVisible();
  });
});
