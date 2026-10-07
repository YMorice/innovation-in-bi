# Innovation in BI

Dossier de travail « Innovation in BI » de Yann. Dépôt git privé :
https://github.com/YMorice/innovation-in-bi (branche `main`, identité locale YMorice).
Le `.gitignore` est une liste blanche : seuls les dossiers qu'il nomme entrent dans le dépôt,
le dossier interdit n'est jamais parcouru. Pour ajouter des fichiers, nommer les chemins
(`git add app supabase …`), jamais `git add -A` ni `git add --force` sur un chemin ignoré.

## Contenu

Mode d'emploi pour Yann : `README.md`.

- `app/index.html` : **l'app unique, déployée sur Netlify** (site `desoutter`).
  Page statique : connexion Supabase Auth (connexion seule, pas d'inscription ; compte dans
  `utilisateur_autorise` ; liens d'invitation/réinitialisation → écran « Choisissez votre mot
  de passe »), onglet Dépôt (découpage dans le worker `IMPORT`, copie gzip dans le bucket
  `exports`, RPC `deposer_cycle`) et tableaux de bord lus en base (`v_cycle_resume`, mesures à
  la demande ; `base.summary()` produit les mêmes champs que `parse()` du worker). Projet
  visé : `config.js`, généré au build Netlify (`netlify.toml` → `build-config.js`) depuis les
  variables `SUPABASE_URL` / `SUPABASE_KEY` du site ; le build refuse une clé secrète.
  Déploiement : **par Git uniquement**, chaque push sur `main` republie le site. Le
  `netlify.toml` racine fixe `base = "app"` (sans lui, Netlify publierait la racine du
  dépôt). Ne plus lancer `netlify deploy` ni glisser-déposer : le push suivant l'écraserait.
- `supabase/migrations/` : schéma (tables en `public`), `import_cycle`, accès sur invitation,
  vue de résumé, `deposer_cycle`. Appliquées à la main dans l'éditeur SQL : le réseau de Yann
  bloque le port 5432, tout passe par HTTPS.
- `supabase/schema_complet.sql` : toutes les migrations fusionnées, pour une base neuve
  (celle des vraies données, à laquelle Claude n'a pas accès). Toute nouvelle migration
  doit aussi y être reportée.
- MCP Supabase : serveur `supabase` (outils `mcp__supabase__*`) en config locale de ce dossier
  (`~/.claude.json`, pas dans le dépôt ; `claude mcp get supabase`), limité par le
  `project_ref` de son URL au projet **synthétique** (celui du `.env`), via HTTPS. La base des
  vraies données est sur le même compte Supabase : ne jamais retirer ni changer ce `project_ref`.
  **Dans ce dossier, n'utiliser que lui** : le connecteur claude.ai « Supabase »
  (`mcp__claude_ai_Supabase__*`) est branché sur un autre compte (projet « Backend ») sans
  rapport avec ce dossier.
- **Aucun projet Supabase en clair dans le dépôt** : ni URL, ni identifiant (`project_ref`), ni
  clé, dans aucun fichier versionné (code, doc, CLAUDE.md). Claude développe et teste sur le
  projet synthétique (`.env`, MCP) ; le site Netlify lit les vraies données via ses propres
  variables d'environnement. Ne jamais écrire `SUPABASE_URL` ni une clé dans `netlify.toml`
  (`[build.environment]` écraserait les variables du site).
- `scripts/charger_cycles.py` : import en masse en ligne de commande (HTTPS, clé secrète).
  Son découpage doit rester identique à `IMPORT` dans `app/index.html`.
- `scripts/generer_synthetiques.py` : générateur d'exports synthétiques (→ `donnees/synthetiques/`,
  avec `verite_terrain.csv` pour le ML).
- `donnees/fichier_ano.xls` : export réel anonymisé (texte tabulé, virgule décimale).
- `archives/plateforme/` : ancienne app Next.js (Vercel), remplacée par `app/`. Ne plus modifier.
- `04 Qualification Outils Coupants/` : **INTERDIT, voir ci-dessous.**

## Dossier interdit : `04 Qualification Outils Coupants/`

**Claude n'a aucun droit sur ce dossier.** Décision explicite de Yann.

Il contient des données confidentielles de qualification d'outils coupants
(essais fournisseurs). Sont interdits, sans exception :

- lire, ouvrir, lister ou rechercher dans ce dossier ou ses sous-dossiers ;
- créer, modifier, renommer, déplacer, copier, archiver ou supprimer quoi que ce soit dedans ;
- en extraire ou en résumer le contenu, ou l'envoyer vers un service externe (MCP, web, artifact…) ;
- le parcourir indirectement : `find`, `grep -r`, `rg`, `ls -R`, `tree`, `du`, `tar`, `zip`,
  Glob/Grep lancés depuis la racine du projet, globs du type `04*`, liens symboliques, sous-agents.

Si une tâche semble exiger ce dossier : **s'arrêter et demander à Yann** de
fournir lui-même l'information. Ne jamais chercher à contourner le blocage.

### Application technique

Le blocage est appliqué par le harness, pas seulement par cette consigne :

- `.claude/hooks/bloquer-dossier-interdit.py` : hook `PreToolUse` sur tous les outils.
  Il refuse (code 2, message explicatif) tout appel qui mentionne le dossier,
  vise un chemin dedans, ou lance une recherche récursive depuis la racine.
- `.claude/settings.json` : règles `permissions.deny` en complément, et
  interdiction pour Claude de modifier `.claude/` (hook et réglages).

Conséquence pratique : pour chercher des fichiers, toujours donner un chemin
précis (un fichier ou un sous-dossier autre que le dossier interdit), jamais la racine.
