# Dynotch docs

The site at <https://aliraza47.github.io/dynotch/>, built with [Astro](https://astro.build) and
deployed to GitHub Pages by `.github/workflows/docs.yml`. Its design lives on the
[Dynotch Docs canvas](https://claude.ai/artifact/VvtyYe8hJrocCB245R4ds3).

It needs Node 22.23.4 or later (`.nvmrc` says which one CI uses).

```bash
npm install
npm run dev       # http://localhost:4321/dynotch/
npm run build     # the site and its search index, in dist/
npm run preview   # the built site, which is the only place search works
```

## Where things are

| Path | What's in it |
|---|---|
| `src/content/docs/*.mdx` | The pages. A file's name is its address |
| `src/data/nav.ts` | The sidebar: its sections, and the pages in each, in order |
| `src/data/site.ts` | The version, the download link and the changelog, read from GitHub's releases at build time |
| `src/styles/global.css` | Lit Glass: the app's colors, surfaces and keycaps |
| `public/screens/` | The screenshots, made by `npm run screens` |

Pages can use these without importing them:

```mdx
<Keys k="⌃⌥K" />
<Path to="Settings → Tray → Keep copies" />
<Note>Worth knowing.</Note>
<Note warn>Worth worrying about.</Note>
<Shot name="12-open-tray" alt="What it shows, for a screen reader." caption="Optional." />
<Shot name="settings-1-general" themed alt="…" />
<Shots min={320}>two or more Shots: a grid, or a row to swipe on a phone</Shots>
```

A page's front matter takes `title`, `description`, an optional shorter `navTitle` for the sidebar,
and an optional `open` button that opens that part of the app through a `dynotch://` link.

A new page needs its slug in `src/data/nav.ts`, or the build stops and says so.

## On a phone

Below 860 points the menu bar and its notch go, because they belong to a Mac. The app hangs from the
top of the screen instead, and a dock at the thumb (`src/components/Dock.astro`) opens sheets for the
docs and everything else. Tables fold into rows and pictures run edge to edge, so a page needs nothing
special for this, but keep a table's first column short: it becomes each row's title.

## Screenshots

`npm run screens` renders every screenshot from the app itself, with sample data, so they can't
drift from it and nothing of yours shows up. `scripts/screens.mjs` lists the scenes and how each is
cropped. To add one, add it there and run it.

Point it at a bundled app rather than a bare binary, because the About page reads its version from
the bundle, and check what comes out before you publish it: an app with real permissions can draw
real devices over the samples.

```bash
npm run screens -- /Applications/Dynotch.app/Contents/MacOS/Dynotch
```

Run it before about 21:40. The sample events sit 12 and 140 minutes after the time you run it, and
later than that they roll over to tomorrow, which changes the calendar scenes.
