const { chromium } = require('playwright');
const path = require('path');
const fs = require('fs');

const targets = [
  { file: 'hero-banner.html', out: 'scramkd-hero-banner.png', width: 1200, height: 320 },
  { file: 'architecture-pipeline.html', out: 'architecture-interlock-flow.png', width: 1200, height: 540 },
  { file: 'telemetry-strip.html', out: 'hardware-badges-strip.png', width: 1200, height: 130 },
  { file: 'social-preview.html', out: 'social-preview.png', width: 1280, height: 640 }
];

async function getBrowser() {
  try {
    return await chromium.launch();
  } catch (err) {
    const chromePath = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
    if (fs.existsSync(chromePath)) {
      return await chromium.launch({ executablePath: chromePath });
    }
    throw err;
  }
}

(async () => {
  const browser = await getBrowser();
  const context = await browser.newContext({
    deviceScaleFactor: 2 // Enforces 2x Retina Resolution
  });

  for (const item of targets) {
    const page = await context.newPage();
    await page.setViewportSize({ width: item.width, height: item.height });
    const filePath = `file://${path.resolve(__dirname, '../docs/brand', item.file)}`;
    await page.goto(filePath, { waitUntil: 'networkidle' });
    
    // Ensure all webfonts and images are completely rendered
    await page.evaluate(() => document.fonts.ready);
    await page.waitForTimeout(500);

    const outPath = path.resolve(__dirname, '../docs/assets', item.out);
    await page.screenshot({ path: outPath, clip: { x: 0, y: 0, width: item.width, height: item.height } });
    console.log(`Rendered: ${item.out} (@2x: ${item.width * 2}x${item.height * 2})`);
    await page.close();
  }

  await browser.close();
})();
