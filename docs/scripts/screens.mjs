#!/usr/bin/env node
// Renders the screenshots these docs use from the app itself, so they can't drift from it.
//
//   npm run screens                   the app in ../build, else ../.build/debug/Dynotch
//   npm run screens -- /path/Dynotch  any other binary
//
// `Dynotch --snapshot` draws each scene with sample data, so nothing of your own shows up.
// A bundled app is better than a bare binary: the About page reads its version from the bundle.
// Run it before about 21:40. The sample events sit 12 and 140 minutes after the time you run it,
// and later than that they roll over to tomorrow, which changes the calendar scenes.

import { execFileSync } from 'node:child_process';
import { existsSync, mkdtempSync, mkdirSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import sharp from 'sharp';

const here = dirname(fileURLToPath(import.meta.url));
const repo = resolve(here, '../..');
const output = resolve(here, '../public/screens');
const manifest = resolve(here, '../src/data/screens.json');

// The widest a stored image gets. Renders are at 2x, so this is 800 points.
const maxWidth = 1600;

// The closed notch and the glance sit at the top of a wide scene: these keep that part, centered
// on the camera, so they read at the width of a page.
const closed = { left: 334, top: 0, width: 900, height: 190 };
const glance = { left: 284, top: 0, width: 1000, height: 300 };

const scenes = {
  // The three cards on the home page, cropped alike so the notch sits the same way in each.
  'card-closed': { from: '05-closed-timer', crop: { left: 334, top: 0, width: 900, height: 335 } },
  'card-glance': { from: 'glance-1-music', crop: { left: 234, top: 0, width: 1100, height: 409 } },
  'card-open': { from: '10-open-nook', crop: { left: 64, top: 0, width: 1440, height: 536 } },

  // The stage on the home page.
  '10-open-nook': null,
  '12-open-tray': null,
  '14-open-focus': null,
  '15-open-control': null,
  '03-closed-music': null,
  'glance-1-music': null,

  // Live activities
  '03-closed-music-crop': { from: '03-closed-music', crop: closed },
  '04-closed-track-peek': closed,
  '05-closed-timer': closed,
  '06-closed-volume': closed,
  '07-closed-charging': closed,
  '08-closed-event': closed,
  '09-closed-notification': closed,
  '09-closed-notification-private': closed,
  '09-closed-notification-other-app': closed,
  '20-closed-timer-and-music': closed,
  '23-closed-event-and-timer': closed,
  '30-closed-muted': closed,
  '31-closed-music-muted': closed,
  '32-closed-mute-notice': closed,
  '33-closed-on-air-camera': closed,
  '34-closed-on-air-mic-muted': closed,
  '40-closed-countdown': closed,
  '42-closed-two-countdowns': closed,
  '44-closed-stopwatch-and-music': closed,
  '45-closed-timer-done': closed,
  '51-closed-long-message': closed,
  '60-closed-download': closed,
  '61-closed-download-size': closed,
  '62-closed-download-and-music': closed,
  '64-closed-downloaded': closed,
  '65-closed-script-notice': closed,
  '70-closed-focus': closed,
  '71-closed-music-and-focus': closed,
  '72-closed-focus-on': closed,
  '73-closed-focus-off': closed,
  '90-closed-screenshot': closed,
  '95-closed-rain': closed,

  // Displays without a camera notch
  '25-virtual-notch-idle': closed,
  '26-virtual-notch-music': closed,
  '27-line-idle': closed,
  '28-line-hover': closed,
  '29-line-music': closed,

  // Glance
  'glance-1-music-crop': { from: 'glance-1-music', crop: glance },
  'glance-2-pomodoro': glance,
  'glance-3-countdown': glance,
  'glance-4-event': glance,
  'glance-5-download': glance,
  'glance-6-message': glance,
  'glance-7-stopwatch': glance,
  'glance-8-today': glance,

  // Command field
  'command-1-empty': null,
  'command-2-timer': null,
  'command-3-sum': null,
  'command-4-reminder': null,
  'command-5-toggle': null,

  // Nook
  '11-open-nook-empty': null,
  '81-open-nook-outputs': null,
  '84-open-nook-live-levels': null,
  '93-open-nook-weather-notes': null,
  '96-open-nook-timer-toggles': null,
  '98-open-nook-shortcuts-calendar': null,
  'widget-mirror': null,
  'widget-notes': null,
  'widget-shortcuts': null,

  // Tray
  '13-open-tray-dropping': null,
  '92-open-tray-selected': null,

  // Focus
  '14-open-focus-notes': null,
  '97-open-focus-busy': null,

  // Control
  '91-open-control-bluetooth': null,

  // Appearance
  '16-open-nook-glass': null,
  '17-open-focus-glass': null,
  '18-open-control-pink-round': null,
  '19-open-tray-teal-square': null,
  'accent-blue-control': null,
  'accent-green-control': null,
  'accent-orange-control': null,
  'accent-red-control': null,
  'accent-yellow-control': null,
  'accent-graphite-control': null,

  // Capture
  'capture-1-selection': null,
  'capture-2-editor-dark': null,
  'capture-4-pinned-dark': null,

  // Settings, in both appearances
  'settings-1-general-dark': null,
  'settings-1-general-light': null,
  'settings-2-appearance-dark': null,
  'settings-2-appearance-light': null,
  'settings-3-activities-dark': null,
  'settings-3-activities-light': null,
  'settings-4-nook-dark': null,
  'settings-4-nook-light': null,
  'settings-5-tray-dark': null,
  'settings-5-tray-light': null,
  'settings-6-focus-dark': null,
  'settings-6-focus-light': null,
  'settings-7-permissions-dark': null,
  'settings-7-permissions-light': null,
  'settings-8-about-dark': null,
  'settings-8-about-light': null,
  'settings-profiles-dark': null,

  // Welcome tour
  'welcome-1-notch-dark': null,
  'welcome-1-notch-light': null,
  'welcome-2-highlights-dark': null,
  'welcome-2-highlights-light': null,
  'welcome-3-permissions-dark': null,
  'welcome-3-permissions-light': null,
  'welcome-4-done-dark': null,
  'welcome-4-done-light': null,
};

const binary =
  process.argv[2] ??
  [join(repo, 'build/Dynotch.app/Contents/MacOS/Dynotch'), join(repo, '.build/debug/Dynotch')].find(existsSync);

if (!binary || !existsSync(binary)) {
  console.error('No Dynotch to render with. Run `swift build` first, or pass a binary.');
  process.exit(1);
}

const sourceOf = (name, entry) => entry?.from ?? name;
const cropOf = (entry) => entry?.crop ?? (entry?.from ? null : entry);

const rendered = mkdtempSync(join(tmpdir(), 'dynotch-screens-'));
try {
  const wanted = [...new Set(Object.entries(scenes).map(([name, entry]) => sourceOf(name, entry)))];
  console.log(`Rendering ${wanted.length} scenes with ${binary}`);
  execFileSync(binary, ['--snapshot', rendered, '--only', wanted.join(',')], { stdio: ['ignore', 'ignore', 'inherit'] });

  rmSync(output, { recursive: true, force: true });
  mkdirSync(output, { recursive: true });

  const sizes = {};
  for (const [name, entry] of Object.entries(scenes)) {
    const source = join(rendered, `${sourceOf(name, entry)}.png`);
    const crop = cropOf(entry);
    let image = sharp(source);
    if (crop) image = image.extract(crop);
    const { width } = crop ?? (await sharp(source).metadata());
    if (width > maxWidth) image = image.resize({ width: maxWidth });
    const file = join(output, `${name}.webp`);
    const info = await image.webp({ quality: 90, effort: 6 }).toFile(file);
    sizes[name] = [info.width, info.height];
  }

  writeFileSync(manifest, `${JSON.stringify(sizes, null, 2)}\n`);
  console.log(`Wrote ${Object.keys(sizes).length} images to ${output}`);
} finally {
  rmSync(rendered, { recursive: true, force: true });
}
