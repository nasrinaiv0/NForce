const { chromium } = require('playwright');
const assert = require('node:assert/strict');
(async () => {
  const browser = await chromium.launch({headless:true});
  try {
    for (const [name, width, height] of [['small-phone',320,760],['phone',390,844],['desktop',1440,900]]) {
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
      // Explicit isolated demo owner persona, not a live authorization override.
      await page.addInitScript(() => localStorage.setItem('nforce.preferences.v2', JSON.stringify({backend:'demo',persona:'owner',locale:'en',reduceMotion:true})));
      await page.goto('http://127.0.0.1:8765/',{waitUntil:'domcontentloaded'});
      await page.getByText(/Good (morning|afternoon|evening)/i).first().waitFor({timeout:30000});
      await page.screenshot({path:'/tmp/nforce-browser/screenshots/'+name+'.png', fullPage:true});
      const body = await page.locator('body').innerText();
      assert.ok(body.trim().length > 30, 'nonempty app content');
      assert.ok(!/Something went wrong|Application error|Unable to resolve module/i.test(body),'no application error screen');
      assert.equal(errors.length,0,errors.join('\n'));
      assert.ok(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 2),'no horizontal viewport overflow');
      console.log(name+' isolated web smoke passed');
      await page.getByText('More',{exact:true}).first().click();
      await page.getByRole('button',{name:'Payroll',exact:true}).first().click({timeout:30000});
      await page.getByText('Monetary payroll review',{exact:true}).waitFor({timeout:30000});
      await page.getByText('Fictional example only — not real payroll.',{exact:true}).waitFor({timeout:10000});
      await page.getByText('₱611.25',{exact:true}).waitFor({timeout:10000});
      await page.getByText(/payable hours/i).first().waitFor({timeout:30000});
      await page.getByText(/export csv/i).first().waitFor({timeout:10000});
      // The DOM contains the full value even when CSS ellipsizes it. Inspect
      // rendered text fragments and computed clipping instead of textContent alone.
      for (const label of ['Payable hours', 'Paid-hour equivalent', 'Unapproved OT']) {
        const exact = page.getByText(label,{exact:true}).first();
        const clipped = await exact.evaluate(el => {
          const card = el.closest('[aria-label]');
          if (!card) return ['missing accessible KPI container'];
          const issues = [];
          const walker = document.createTreeWalker(card, NodeFilter.SHOW_TEXT);
          for (let n = walker.nextNode(); n; n = walker.nextNode()) {
            if (!n.textContent.trim()) continue;
            const parent = n.parentElement;
            const css = getComputedStyle(parent);
            const clamp = css.getPropertyValue('-webkit-line-clamp');
            if (css.textOverflow === 'ellipsis' || (clamp && clamp !== 'none' && Number(clamp) > 0)) issues.push('clamped: '+n.textContent);
            const range = document.createRange();
            range.selectNodeContents(n);
            const bounds = card.getBoundingClientRect();
            for (const rect of range.getClientRects()) {
              if (rect.left < bounds.left-1 || rect.right > bounds.right+1 || rect.top < bounds.top-1 || rect.bottom > bounds.bottom+1) issues.push('outside KPI: '+n.textContent);
            }
          }
          return issues;
        });
        assert.deepEqual(clipped, [], name+' '+label+' full text');
      }
      console.log(name+' payroll KPI full-text bounds passed');
      await page.screenshot({path:'/tmp/nforce-browser/screenshots/'+name+'-payroll.png',fullPage:true});
      assert.ok(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 2),'payroll viewport overflow');
      assert.equal(errors.length,0,errors.join('\n'));
      console.log(name+' payroll attendance demo smoke passed');
      await page.close();
    }
    // Every role gets a fresh fictional session. No hosted API is contacted.
    for (const role of ['staff','supervisor','manager','operations','hr','payroll','executive','org_admin','owner']) {
      const page = await browser.newPage({viewport:{width:390,height:844},locale:'en-US',reducedMotion:'reduce'});
      const errors=[];
      page.on('pageerror',e=>errors.push(e.message));
      await page.route('**/*',async route=>{
        const url=new URL(route.request().url());
        if(url.origin!=='http://127.0.0.1:8765') return route.abort();
        if(route.request().isNavigationRequest() && url.pathname==='/more/payroll') return route.fulfill({response:await route.fetch({url:'http://127.0.0.1:8765/'})});
        return route.continue();
      });
      await page.addInitScript(role=>localStorage.setItem('nforce.preferences.v2',JSON.stringify({backend:'demo',persona:role,locale:'en',reduceMotion:true})),role);
      await page.goto('http://127.0.0.1:8765/',{waitUntil:'domcontentloaded'});
      await page.getByText(/Good (morning|afternoon|evening)/i).first().waitFor({timeout:30000});
      await page.screenshot({path:'/tmp/nforce-browser/screenshots/role-'+role+'-home.png',fullPage:true});
      await page.getByText('More',{exact:true}).first().click();
      await page.getByRole('button',{name:'Payroll',exact:true}).first().waitFor({timeout:30000});
      await page.screenshot({path:'/tmp/nforce-browser/screenshots/role-'+role+'-menu.png',fullPage:true});
      await page.getByRole('button',{name:'Payroll',exact:true}).first().click({timeout:30000});
      const management=role==='payroll'||role==='owner';
      if(management){
        await page.getByText('Monetary payroll review',{exact:true}).waitFor({timeout:30000});
        await page.getByText('₱611.25',{exact:true}).waitFor({timeout:10000});
        assert.equal(await page.getByText('Personal payroll',{exact:true}).count(),0,role);
      }else{
        await page.getByText('Personal payroll',{exact:true}).waitFor({timeout:30000});
        await page.getByText('My SSS',{exact:true}).waitFor({timeout:10000});
        await page.getByText('₱26,542.45',{exact:true}).waitFor({timeout:10000});
        assert.equal(await page.getByText('Monetary payroll review',{exact:true}).count(),0,role);
        assert.equal(await page.getByText(/employer contribution|employer cost/i).count(),0,role);
        assert.equal(await page.getByText(/export csv/i).count(),0,role);
      }
      await page.screenshot({path:'/tmp/nforce-browser/screenshots/role-'+role+'-payroll.png',fullPage:true});
      assert.ok(await page.evaluate(()=>document.documentElement.scrollWidth<=window.innerWidth+2),role+' viewport overflow');
      assert.equal(errors.length,0,errors.join('\n'));
      console.log('role '+role+' payroll visibility passed');
      // Return through browser history: nested stack screens keep hidden headings mounted.
      await page.goBack();
      await page.waitForURL(/\/more\/?$/,{timeout:30000});
      await page.getByRole('button',{name:'My profile',exact:true}).click();
      await page.getByRole('button',{name:'My employee record',exact:true}).waitFor({timeout:30000});
      assert.equal(await page.getByText('Language',{exact:true}).count(),0,role+' profile does not contain settings');
      await page.screenshot({path:'/tmp/nforce-browser/screenshots/role-'+role+'-profile.png',fullPage:true});
      await page.getByRole('button',{name:'My payslip',exact:true}).click();
      await page.getByText('Payslip detail',{exact:true}).waitFor({timeout:30000});
      await page.getByRole('button',{name:'Show work and earnings evidence',exact:true}).click();
      await page.getByText('Fictional office',{exact:true}).waitFor({timeout:10000});
      assert.equal(await page.getByText(/employer contribution|employer cost/i).count(),0,role+' own payslip');
      await page.screenshot({path:'/tmp/nforce-browser/screenshots/role-'+role+'-payslip.png',fullPage:true});
      await page.goBack();
      await page.waitForURL(/\/more\/my-profile\/?$/,{timeout:30000});
      await page.goBack();
      await page.waitForURL(/\/more\/?$/,{timeout:30000});
      await page.getByRole('button',{name:'Settings',exact:true}).click();
      await page.getByText('Language',{exact:true}).waitFor({timeout:30000});
      assert.equal(await page.getByRole('button',{name:'My employee record',exact:true}).count(),0,role+' settings does not contain profile records');
      await page.screenshot({path:'/tmp/nforce-browser/screenshots/role-'+role+'-settings.png',fullPage:true});
      assert.ok(await page.evaluate(()=>document.documentElement.scrollWidth<=window.innerWidth+2),role+' settings viewport overflow');
      assert.equal(errors.length,0,errors.join('\n'));
      console.log('role '+role+' profile, personal payslip and settings separation passed');
      await page.close();
    }
  } finally { await browser.close(); }
})().catch(e => { console.error(e); process.exitCode=1; });
