import { getCollection } from 'astro:content';

export interface NavGroup {
  title: string;
  /** The color of the matching badge in the app's Settings sidebar. */
  tint: string;
  icon: 'start' | 'notch' | 'features' | 'brush' | 'terminal' | 'book';
  /** One line for the list of sections on a phone. */
  summary: string;
  /** Page slugs, in reading order. */
  pages: string[];
}

export const nav: NavGroup[] = [
  {
    title: 'Get started',
    tint: '#7087B3',
    icon: 'start',
    summary: 'Install, first run, opening and closing',
    pages: ['install', 'first-run', 'opening', 'updating'],
  },
  {
    title: 'The notch',
    tint: '#9975FF',
    icon: 'notch',
    summary: 'Live activities, the glance, the four tabs',
    pages: ['live-activities', 'glance', 'command-field', 'nook', 'tray', 'focus', 'control'],
  },
  {
    title: 'Features',
    tint: '#FF8F3D',
    icon: 'features',
    summary: 'Capture, notifications, the microphone',
    pages: ['capture', 'notifications', 'microphone', 'downloads', 'calendar-weather', 'audio-keys'],
  },
  {
    title: 'Make it yours',
    tint: '#FF6694',
    icon: 'brush',
    summary: 'Appearance, profiles, settings',
    pages: ['appearance', 'profiles', 'displays', 'settings', 'shortcuts'],
  },
  {
    title: 'Automate',
    tint: '#33B8C7',
    icon: 'terminal',
    summary: 'The dynotch command and links',
    pages: ['dynotch-command', 'links', 'recipes'],
  },
  {
    title: 'Reference',
    tint: '#42BD73',
    icon: 'book',
    summary: 'Permissions, privacy, energy',
    pages: ['permissions', 'privacy', 'energy', 'limitations', 'troubleshooting', 'build', 'changelog'],
  },
];

/** What each page goes by in lists: the sidebar, the home page, next and previous. */
export async function getPageNames() {
  const docs = await getCollection('docs');
  const names = new Map(docs.map((doc) => [doc.id, doc.data.navTitle ?? doc.data.title]));
  names.set('changelog', 'Changelog');
  for (const slug of nav.flatMap((group) => group.pages)) {
    if (!names.has(slug)) throw new Error(`The sidebar lists ${slug}, which has no page.`);
  }
  return names;
}
