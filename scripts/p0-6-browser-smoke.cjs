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
        await page.getByText('Payroll disputes',{exact:true}).waitFor({timeout:10000});
        assert.equal(await page.getByText('Pending independent approval',{exact:true}).count(),1);
        for(const button of await page.getByRole('button',{name:'Review case',exact:true}).all())assert.ok(await button.isDisabled());
        await page.getByText('Payroll disputes',{exact:true}).scrollIntoViewIfNeeded();
        await page.screenshot({path:'/tmp/nforce-browser/screenshots/role-'+role+'-disputes.png'});
      }else{
        await page.getByText('Personal payroll',{exact:true}).waitFor({timeout:30000});
        await page.getByText('My SSS',{exact:true}).waitFor({timeout:10000});
        await page.getByText('₱26,542.45',{exact:true}).first().waitFor({timeout:10000});
        assert.equal(await page.getByText('Monetary payroll review',{exact:true}).count(),0,role);
        assert.equal(await page.getByText(/employer contribution|employer cost/i).count(),0,role);
        assert.equal(await page.getByText(/export csv/i).count(),0,role);
        assert.equal(await page.getByText('Payroll disputes',{exact:true}).count(),0,role);
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
      await page.getByText('Payslip history',{exact:true}).waitFor({timeout:30000});
      await page.getByText('Payslip detail',{exact:true}).waitFor({timeout:30000});
      await page.getByText('Personal payroll',{exact:true}).first().scrollIntoViewIfNeeded();
      await page.screenshot({path:'/tmp/nforce-browser/screenshots/role-'+role+'-payslip-summary.png',fullPage:true});
      await page.getByRole('button',{name:'Show work and earnings evidence',exact:true}).click();
      await page.getByText('Fictional office',{exact:true}).first().waitFor({timeout:10000});
      assert.equal(await page.getByText(/employer contribution|employer cost/i).count(),0,role+' own payslip');
      await page.getByText('Regular work · Overtime',{exact:true}).waitFor({timeout:10000});
      await page.getByText('₱287.67',{exact:true}).last().waitFor({timeout:10000});
      await page.getByText('Regular work · Overtime',{exact:true}).scrollIntoViewIfNeeded();
      if(role==='staff'){
        await page.getByRole('button',{name:'Question this item',exact:true}).first().click();
        await page.getByText('Fictional preview. Submission is disabled.',{exact:true}).waitFor({timeout:10000});
        assert.ok(await page.getByRole('button',{name:'Submit dispute',exact:true}).isDisabled());
        await page.getByRole('button',{name:'Cancel',exact:true}).click();
        const downloadPromise=page.waitForEvent('download');
        await page.getByRole('button',{name:'Download confidential PDF',exact:true}).click();
        const download=await downloadPromise;
        await download.saveAs('/tmp/nforce-browser/screenshots/sample-nforce-payslip.pdf');
        const pdfPath='/tmp/nforce-browser/screenshots/sample-nforce-payslip.pdf';
        const pdf=require('node:fs').readFileSync(pdfPath,'utf8');
        const extracted=require('node:child_process').execFileSync('pdftotext',['-layout',pdfPath,'-'],{encoding:'utf8'});
        assert.ok(pdf.startsWith('%PDF-1.4')&&pdf.includes('/FontFile2')&&extracted.includes('FICTIONAL SAMPLE')&&extracted.includes('₱26,542.45')&&!/employer contribution|employer cost/i.test(extracted));
        const embedded=pdf.match(/6 0 obj\n<< \/Length (\d+) \/Filter \/ASCII85Decode \/Length1 (\d+) >>\nstream\n([^\n]*)\nendstream/);
        assert.ok(embedded,'embedded ASCII85 font stream');
        const font85=embedded[3];
        assert.ok(font85.endsWith('~>')&&font85.length===Number(embedded[1])&&Number(embedded[2])===343308);
        const decodedFont=[];let digits=[];
        for(const c of font85.slice(0,-2)){
          if(c==='z'){assert.equal(digits.length,0);decodedFont.push(0,0,0,0);continue;}
          assert.ok(c.charCodeAt(0)>=33&&c.charCodeAt(0)<=117);
          digits.push(c.charCodeAt(0)-33);
          if(digits.length===5){const word=digits.reduce((a,b)=>a*85+b,0);assert.ok(word<=0xffffffff);decodedFont.push(Math.floor(word/16777216)&255,Math.floor(word/65536)&255,Math.floor(word/256)&255,word&255);digits=[];}
        }
        assert.equal(digits.length,0,'original font length is divisible by four');
        assert.equal(decodedFont.length,343308);
        assert.equal(require('node:crypto').createHash('sha256').update(Buffer.from(decodedFont)).digest('hex'),'5f5d02214616ec855dff916d40d58bf87520be052dcdbc237d091f222c13aaa4');
        assert.ok(Buffer.byteLength(pdf,'utf8')<450000,'PDF size budget');
        require('node:child_process').execFileSync('pdftoppm',['-f','1','-l','1','-r','120','-png',pdfPath,'/tmp/nforce-browser/screenshots/sample-payslip-render']);
      }
      await page.screenshot({path:'/tmp/nforce-browser/screenshots/role-'+role+'-payslip.png',fullPage:true});
      assert.ok(await page.evaluate(()=>document.documentElement.scrollWidth<=window.innerWidth+2),role+' payslip viewport overflow');
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
    for(const [name,width,height,appearance] of [['compact-dark',320,760,'dark'],['tablet-light',768,1024,'light'],['desktop-dark',1440,900,'dark']]){
      const page=await browser.newPage({viewport:{width,height},locale:'en-US',reducedMotion:'reduce',colorScheme:appearance});
      await page.route('**/*',async route=>new URL(route.request().url()).origin==='http://127.0.0.1:8765'?route.continue():route.abort());
      await page.addInitScript(appearance=>localStorage.setItem('nforce.preferences.v2',JSON.stringify({backend:'demo',persona:'staff',locale:'en',appearance,reduceMotion:true})),appearance);
      await page.goto('http://127.0.0.1:8765/',{waitUntil:'domcontentloaded'});
      await page.getByText(/Good (morning|afternoon|evening)/i).first().waitFor({timeout:30000});
      await page.getByText('More',{exact:true}).first().click();
      await page.getByRole('button',{name:'My profile',exact:true}).click();
      await page.getByRole('button',{name:'My payslip',exact:true}).click();
      await page.getByText('Payslip history',{exact:true}).waitFor({timeout:30000});
      await page.getByText('₱26,542.45',{exact:true}).first().waitFor({timeout:10000});
      await page.screenshot({path:'/tmp/nforce-browser/screenshots/payslip-'+name+'.png',fullPage:true});
      const evidence=page.getByRole('button',{name:'Show work and earnings evidence',exact:true});
      await evidence.click();
      const overtime=page.getByText('Regular work · Overtime',{exact:true});
      await overtime.waitFor({timeout:10000});
      // React Native web uses nested scroll containers; capture the actual visible evidence card.
      await overtime.evaluate(el=>el.scrollIntoView({block:'start',inline:'nearest'}));
      await page.screenshot({path:'/tmp/nforce-browser/screenshots/payslip-'+name+'-evidence.png'});
      assert.ok(await page.evaluate(()=>document.documentElement.scrollWidth<=window.innerWidth+2),name+' no overflow');
      await page.close();
    }
  } finally { await browser.close(); }
})().catch(e => { console.error(e); process.exitCode=1; });
