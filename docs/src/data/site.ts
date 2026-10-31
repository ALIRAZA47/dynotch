import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { marked } from 'marked';

export const repository = 'ALIRAZA47/dynotch';
export const repositoryURL = `https://github.com/${repository}`;
export const latestReleaseURL = `${repositoryURL}/releases/latest`;

export interface Release {
  version: string;
  date: Date;
  url: string;
  dmg?: string;
  html: string;
}

/** The sections of a release's notes worth keeping: the rest is the same on every release. */
const keptSections = /^## (What's new|What's in it|Fixed)/;

function highlights(notes: string) {
  const sections = notes.split(/^(?=## )/m).filter((section) => keptSections.test(section));
  return sections
    .map((section) => section.replace(/^## What's new in .*\n/, '').replace(/^## /m, '### '))
    .join('\n')
    .trim();
}

async function fetchReleases(): Promise<Release[]> {
  const headers: Record<string, string> = { Accept: 'application/vnd.github+json' };
  if (process.env.GITHUB_TOKEN) headers.Authorization = `Bearer ${process.env.GITHUB_TOKEN}`;
  const response = await fetch(`https://api.github.com/repos/${repository}/releases?per_page=100`, { headers });
  if (!response.ok) throw new Error(`GitHub answered ${response.status}`);
  const releases: any[] = await response.json();
  return Promise.all(
    releases
      .filter((release) => !release.draft && !release.prerelease)
      .map(async (release) => ({
        version: release.tag_name.replace(/^v/, ''),
        date: new Date(release.published_at),
        url: release.html_url,
        dmg: release.assets.find((asset: any) => asset.name.endsWith('.dmg'))?.browser_download_url,
        html: await marked.parse(highlights(release.body ?? '')),
      })),
  );
}

let releases: Promise<Release[]> | undefined;

/** Every published release, newest first. Asked for once a build. */
export function getReleases() {
  releases ??= fetchReleases().catch((error) => {
    // A published site shouldn't go out without them; a laptop on a plane can do without.
    if (process.env.CI) throw error;
    console.warn(`Can't read the releases from GitHub: ${error.message}`);
    return [];
  });
  return releases;
}

/** What the app itself says it is, for when GitHub can't be asked. */
function bundleVersion() {
  const plist = readFileSync(resolve(process.cwd(), '../Support/Info.plist'), 'utf8');
  return plist.match(/CFBundleShortVersionString<\/key>\s*<string>([^<]+)/)?.[1] ?? '';
}

/** The version to offer, and the most direct link to it. */
export async function getLatest() {
  const [latest] = await getReleases();
  return { version: latest?.version ?? bundleVersion(), download: latest?.dmg ?? latestReleaseURL };
}
