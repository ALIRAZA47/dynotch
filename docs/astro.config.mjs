import { defineConfig } from 'astro/config';
import mdx from '@astrojs/mdx';
import sitemap from '@astrojs/sitemap';

export default defineConfig({
  site: 'https://aliraza47.github.io',
  base: '/dynotch',
  trailingSlash: 'always',
  integrations: [mdx(), sitemap()],
  markdown: {
    // Token colors come from the theme's variables, so code follows the page's light and dark.
    shikiConfig: { theme: 'css-variables' },
  },
});
