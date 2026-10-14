"""Render the 手繪 scene pictures for the iPhone themes (Sources/Backgrounds).

    pip install playwright pillow && python -m playwright install chromium
    python3 ios/tools/render_scenes.py

The pictures are drawn by organic-bg.js (a copy of the one used by the desktop reader and the
JLPT lessons reader), so the iPhone shows exactly the same scenes. For every theme it writes:

    organic-<scene>-<variant>.jpg         the phone page, 440 x 956 pt at 3x (largest iPhone)
    organic-<scene>-<variant>-wide.jpg    the desktop composition for iPad and landscape screens
    organic-<scene>-<variant>-swatch.jpg  the theme-picker miniature (92 x 66 pt at 3x)

ReaderTheme.scenes in Palette.swift lists the same ids; ThemeTests checks that every theme
there has its three pictures in the app.
"""
import asyncio
import base64
import io
import json
import pathlib

from PIL import Image
from playwright.async_api import async_playwright

HERE = pathlib.Path(__file__).resolve().parent
OUT = HERE.parent / 'Sources' / 'Backgrounds'
ENGINE = HERE / 'organic-bg.js'

# (suffix, width, height, scale, device, quality); None = the picker miniature.
SIZES = [
    ('', 440, 956, 3, 'phone', 80),
    ('-wide', 1366, 1024, 1.5, 'desktop', 80),
    ('-swatch', 92, 66, 3, None, 86),
]

PAGE = '<!doctype html><meta charset="utf-8"><body style="margin:0"><canvas id="c"></canvas>'

RENDER = '''async ([key, w, h, scale, device]) => {
  const preset = OrganicBG.presets().find(p => p.key === key);
  const c = document.getElementById('c');
  c.style.width = w + 'px'; c.style.height = h + 'px';
  if (device) OrganicBG.paint(c, { scene: preset.scene, variant: preset.variant, device, width: w, height: h, dpr: scale });
  else {
    // The whole desktop picture, made small: logical 1200 px wide, drawn at the swatch's pixel size.
    const W = 1200, H = Math.round(W * h / w);
    OrganicBG.paint(c, { scene: preset.scene, variant: preset.variant, device: 'desktop', width: W, height: H, dpr: w * scale / W });
  }
  return c.toDataURL('image/png');
}'''


async def main():
    OUT.mkdir(parents=True, exist_ok=True)
    async with async_playwright() as p:
        browser = await p.chromium.launch()
        page = await browser.new_page()
        await page.set_content(PAGE)
        await page.add_script_tag(content=ENGINE.read_text(encoding='utf-8'))
        presets = await page.evaluate('OrganicBG.presets()')
        for preset in presets:
            for suffix, w, h, scale, device, quality in SIZES:
                data = await page.evaluate(RENDER, [preset['key'], w, h, scale, device])
                image = Image.open(io.BytesIO(base64.b64decode(data.split(',', 1)[1]))).convert('RGB')
                target = OUT / f"{preset['key']}{suffix}.jpg"
                image.save(target, 'JPEG', quality=quality, optimize=True, progressive=False)
                print(f'{target.name:40} {image.width}x{image.height} {target.stat().st_size // 1024} KB')
        (HERE / 'scenes.json').write_text(json.dumps(presets, ensure_ascii=False, indent=1) + '\n', encoding='utf-8')
        await browser.close()


asyncio.run(main())
