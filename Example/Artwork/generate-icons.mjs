// Run from the repository root after installing the isolated renderer:
// npm install --prefix .build/icon-tools --no-package-lock --no-save @resvg/resvg-js@2.6.2
// node Example/Artwork/generate-icons.mjs
import { readFileSync, writeFileSync } from 'node:fs';
import { createRequire } from 'node:module';

const require = createRequire(new URL('../../.build/icon-tools/package.json', import.meta.url));
const { Resvg } = require('@resvg/resvg-js');
const source = readFileSync(new URL('AppIcon.svg', import.meta.url), 'utf8');
const shared = new URL('../MPVUIExample/Shared/', import.meta.url);
const foreground = source.replace('width="1254" height="1254"', 'width="1024" height="1024"');

// Use a brighter grayscale ramp for clear/tinted appearances, preserving the folds.
function luminance(hex) {
  const rgb = [0, 2, 4].map(offset => parseInt(hex.slice(offset, offset + 2), 16) / 255);
  return rgb[0] * 0.2126 + rgb[1] * 0.7152 + rgb[2] * 0.0722;
}
const stops = [...foreground.matchAll(/stop-color="#([0-9a-fA-F]{6})"/g)];
const values = stops.map(match => luminance(match[1]));
const minimum = Math.min(...values);
const maximum = Math.max(...values);
const mono = foreground.replace(/stop-color="#([0-9a-fA-F]{6})"/g, (_, hex) => {
  const normalized = (luminance(hex) - minimum) / (maximum - minimum);
  const gray = Math.round(255 * (0.55 + 0.45 * normalized)).toString(16).padStart(2, '0');
  return `stop-color="#${gray.repeat(3)}"`;
});
writeFileSync(new URL('AppIcon.icon/Assets/Ribbon.svg', shared), foreground);
writeFileSync(new URL('AppIcon.icon/Assets/Ribbon-Mono.svg', shared), mono);

// tvOS still uses a rectangular parallax image stack over its opaque black layer.
for (const [name, width, height, scales] of [
  ['AppIcon', 400, 240, [1, 2]],
  ['AppIcon-AppStore', 1280, 768, [1]],
]) {
  const nested = source.replace(
    'width="1254" height="1254"',
    `x="${(width - height) / 2}" y="0" width="${height}" height="${height}"`,
  );
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="${width}" height="${height}" viewBox="0 0 ${width} ${height}">${nested}</svg>`;
  for (const scale of scales) {
    const output = new URL(
      `Assets.xcassets/AppIconTV.brandassets/${name}.imagestack/Foreground.imagestacklayer/Content.imageset/foreground@${scale}x.png`,
      shared,
    );
    const renderer = new Resvg(svg, { fitTo: { mode: 'width', value: width * scale } });
    writeFileSync(output, renderer.render().asPng());
  }
}
