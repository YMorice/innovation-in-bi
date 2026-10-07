# Innovation in BI : cycles de perçage

Stockage des exports de cycles de perçage dans Supabase, dépôt et tableaux de bord
dans une seule page web.

```
site/           → le site publié par Netlify à chaque push (Astro) : landing à la racine, app sous /app/
app/            → l'app (une seule page : index.html), recopiée dans le site au build
supabase/       → base : schema_complet.sql (base neuve) et migrations/ (historique)
scripts/        → outils en ligne de commande (import en masse, données synthétiques)
donnees/        → fichier_ano.xls (export réel anonymisé) et synthetiques/ (600 cycles)
archives/       → ancienne plateforme Next.js (remplacée par app/), plus utilisée
```

## Mettre en ligne

1. **Base** (une fois) : dans l'éditeur SQL d'un projet Supabase vide, lancer
   `supabase/schema_complet.sql`. Sur une base existante, lancer seulement les
   migrations de `supabase/migrations/` pas encore appliquées, dans l'ordre.
2. **Supabase > Authentication** :
   - Sign In / Providers : décocher « Allow new users to sign up » et « Allow anonymous sign-ins » ;
   - URL Configuration : Site URL = l'adresse Netlify du site (ex. `https://percage.netlify.app/`).
     Les liens des e-mails arrivent sur la landing, qui les passe à l'app (`/app/`).
3. **Netlify > Site configuration > Environment variables** : `SUPABASE_URL` et
   `SUPABASE_KEY` (clé publishable ou anon, faite pour être publique : Supabase > Project
   Settings > API Keys). Jamais la clé secrète : le build la refuse.
4. **Lier le site au dépôt GitHub** (une fois) : Netlify > Project configuration > Build &
   deploy > Continuous deployment > Manage repository > Link to a different repository >
   GitHub > `YMorice/innovation-in-bi`, branche `main`. Laisser vides Base directory, Build
   command et Publish directory : le `netlify.toml` racine envoie le build dans `site/`.
5. **Mettre à jour** : `git push` sur `main`, et c'est tout. Netlify lance le build
   (`site/netlify.toml` : `build-config.js` écrit `config.js` avec l'URL et la clé, puis
   Astro construit la landing et y recopie l'app sous `/app/`) et publie `site/dist/`.
   Plus de `netlify deploy` ni de glisser-déposer : le push suivant écraserait ce
   déploiement manuel.

Voir le site en local : `cd site && npm install && npm run build && npm run preview`.

## Donner accès à quelqu'un

Aucune inscription n'est possible : un compte n'existe que si son e-mail est autorisé.

```sql
insert into public.utilisateur_autorise (email) values ('prenom.nom@exemple.fr');
```

Puis Authentication > Users > Add user > **Send invitation**. La personne clique le lien
de l'e-mail, arrive sur la page, choisit son mot de passe. Mot de passe oublié :
**Send password recovery** sur l'utilisateur, même écran.

Retirer quelqu'un : `delete from public.utilisateur_autorise where email = '…';`
(accès coupé immédiatement), puis supprimer l'utilisateur dans Authentication > Users.

## La page (`app/index.html`, en ligne sous `/app/`)

- **Dépôt** : fichiers `.xls` ou dossiers entiers. Chaque fichier est découpé dans le
  navigateur, sa copie compressée va dans le bucket privé `exports`, puis la fonction
  `deposer_cycle` l'intègre en base et le note au journal. Un fichier déjà importé est
  reconnu. Un `.csv` avec une colonne `source_file` (ex. `verite_terrain.csv`) est joint
  aux cycles des tableaux de bord, sur le poste seulement.
- **Tableau de bord / Cycle / Données** : lus en base (`v_cycle_resume`, mesures à la
  demande), filtres, graphiques configurables, export CSV.

## Scripts

```bash
python scripts/charger_cycles.py donnees/synthetiques/ --parallele 4   # import en masse (clé secrète du .env)
pip install numpy
python scripts/generer_synthetiques.py --cycles 600                     # -> donnees/synthetiques/
```

`charger_cycles.py` lit `SUPABASE_URL` et `SUPABASE_SECRET_KEY` dans `.env` et passe par
HTTPS. Son découpage doit rester identique à celui de la page (`IMPORT` dans le worker).

## Données synthétiques

`generer_synthetiques.py` simule un parc de perçage et écrit des exports au format exact
des vrais : on construit dashboards et modèles dessus, puis on bascule sur les vraies
données sans rien changer.

- 3 boîtiers (un moteur chacun), 6 têtes, `--jours` jours ouvrés en deux équipes.
- 3 programmes : Ti/Al/Ti en 3 étapes (calqué sur l'export réel), CFRP/Al, Al seul.
  Le Pset 0 passe de la version 9 à 10 en cours de période ; un boîtier change de firmware.
- Usure d'outil : couple et poussée croissent avec `Head Local Counter 1` ; l'outil est
  changé en fin de vie ou après une casse.
- Anomalies : `casse_outil` (stop code 4), `bourrage_copeaux`, `epaisseur_hors_tolerance`.
- Signaux calibrés sur `donnees/fichier_ano.xls`. Volume : ~0,5 Mo de base par cycle.

`donnees/synthetiques/verite_terrain.csv` donne pour chaque fichier ce qu'aucun export réel
ne contient (usure `tool_wear`, outil, anomalie injectée, épaisseurs) : c'est la cible des
modèles, jamais une variable d'entrée.

Les cycles synthétiques ont `cycle.is_synthetic = true`. Pour tous les supprimer :
`select public.purge_synthetic();`
