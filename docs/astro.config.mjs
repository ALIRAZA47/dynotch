import { defineConfig } from 'astro/config';
import mdx from '@astrojs/mdx';
import sitemap from '@astrojs/sitemap';

export default defineConfig({
  // The site has its own domain, so it sits at the root. Pages sends the github.io address here.
  site: 'https://dynotch.alirazakhan.me',
  trailingSlash: 'always',
  integrations: [mdx(), sitemap()],
  markdown: {
    // Token colors come from the theme's variables, so code follows the page's light and dark.
    shikiConfig: { theme: 'css-variables' },
  },
});
