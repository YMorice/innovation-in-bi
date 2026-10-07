// Site publié par Netlify : la landing (src/pages/) à la racine, l'app sous /app/.
// L'app reste une page statique hors d'Astro (../app/index.html) : elle est recopiée
// telle quelle à la fin du build, avec le config.js que build-config.js écrit à côté d'elle.
import { defineConfig } from "astro/config";
import { copyFileSync, existsSync, mkdirSync } from "node:fs";

const APP = new URL("../app/", import.meta.url);

export default defineConfig({
  integrations: [{
    name: "app",
    hooks: {
      "astro:build:done": ({ dir, logger }) => {
        const out = new URL("app/", dir);
        mkdirSync(out, { recursive: true });
        copyFileSync(new URL("index.html", APP), new URL("index.html", out));
        // Sur Netlify, build-config.js l'a écrit juste avant (et échoue sans variables).
        if (existsSync(new URL("config.js", APP))) copyFileSync(new URL("config.js", APP), new URL("config.js", out));
        else logger.warn("app/config.js absent : l'app affichera « Page non configurée ».");
        logger.info("app recopiée dans /app/");
      },
    },
  }],
});
