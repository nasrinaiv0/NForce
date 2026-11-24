const { chromium } = require('playwright');
const assert = require('node:assert/strict');
(async () => {
  const browser = await chromium.launch({headless:true});
  try {
    for (const [name, width, height] of [['phone',390,844],['desktop',1440,900]]) {
      const page = await browser.newPage({ viewport:{width,height}, locale:'en-US', reducedMotion:'reduce' });
      const errors = [];
      page.on('pageerror', error => errors.push(error.message));
      // No external requests or hosted tenant credentials in this acceptance.
      await page.route('**/*', async route => {
        const url = new URL(route.request().url());
        if (url.origin !== 'http://127.0.0.1:8765') return route.abort();
        if (route.request().isNavigationRequest() && url.pathname === '/more/payroll') {
          const response = await route.fetch({url:'http://127.0.0.1:8765/'});
          return route.fulfill({response});
        }
        return route.continue();
      });
      await page.goto('http://127.0.0.1:8765/',{waitUntil:'domcontentloaded'});
      await page.waitForFunction(() => document.body.innerText.trim().length > 30, {timeout:30000});
      await page.screenshot({path:'/tmp/nforce-browser/screenshots/'+name+'.png', fullPage:true});
      const body = await page.locator('body').innerText();
      assert.ok(body.trim().length > 30, 'nonempty app content');
      assert.ok(!/Something went wrong|Application error|Unable to resolve module/i.test(body),'no application error screen');
      assert.equal(errors.length,0,errors.join('\n'));
      assert.ok(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 2),'no horizontal viewport overflow');
      console.log(name+' isolated web smoke passed');
      await page.goto('http://127.0.0.1:8765/more/payroll',{waitUntil:'domcontentloaded'});
      await page.getByText('Monetary payroll review',{exact:true}).waitFor({timeout:30000});
      await page.getByText('Fictional example only — not real payroll.',{exact:true}).waitFor({timeout:10000});
      await page.getByText('₱611.25',{exact:true}).waitFor({timeout:10000});
      await page.screenshot({path:'/tmp/nforce-browser/screenshots/'+name+'-payroll.png',fullPage:true});
      assert.ok(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 2),'payroll viewport overflow');
      assert.equal(errors.length,0,errors.join('\n'));
      console.log(name+' payroll monetary demo smoke passed');
      await page.close();
    }
  } finally { await browser.close(); }
})().catch(e => { console.error(e); process.exitCode=1; });
