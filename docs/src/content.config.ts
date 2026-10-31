import { defineCollection } from 'astro:content';
import { glob } from 'astro/loaders';
import { z } from 'astro/zod';

const docs = defineCollection({
  loader: glob({ pattern: '*.mdx', base: './src/content/docs' }),
  schema: z.object({
    title: z.string(),
    /** One line under the title, in the voice of the app's own Settings pages. */
    description: z.string(),
    /** A shorter name for the sidebar. */
    navTitle: z.string().optional(),
    /** A button beside the title that opens this part of the app, like the ones in its Settings. */
    open: z.object({ label: z.string(), href: z.string() }).optional(),
  }),
});

export const collections = { docs };
