# Plateforme de dépôt des cycles de perçage

Application Next.js (App Router) à héberger sur Vercel. On s'y connecte, on dépose des
exports `.xls` (fichiers ou dossiers entiers) et chaque fichier est intégré dans Supabase.

## Fonctionnement

1. Le navigateur lit le fichier, en extrait la courbe de couple (affichée dans la file)
   et l'envoie compressé en gzip : un export de 650 ko pèse ~52 ko à l'envoi, loin de la
   limite de 4,5 Mo des fonctions Vercel.
2. `app/api/import/route.ts` vérifie la session, décompresse, découpe le fichier
   (`lib/parser.ts`) et appelle la fonction SQL `import_cycle` avec la clé secrète :
   tout le cycle est écrit dans une seule transaction.
3. La copie compressée du fichier est rangée dans le bucket privé `exports`
   (`importes/` ou `erreurs/`), et le dépôt est noté dans `import_file` (historique de la page).

Un fichier déjà importé (même contenu) ou un cycle déjà connu (même boîtier et même
Drilling Cycle ID) est signalé « déjà en base » et n'est pas réécrit.

`lib/parser.ts` et `ingestion/charger_cycles.py` doivent produire exactement le même
document : toute évolution du format se fait des deux côtés.

## Mise en service

1. **Base** : exécuter `supabase/migrations/20260923120000_import_plateforme.sql` dans
   l'éditeur SQL du projet (après la migration initiale).
2. **Comptes** : dans Supabase → Authentication, désactiver les inscriptions libres
   (Sign In / Providers → *Allow new users to sign up*), puis créer chaque utilisateur
   (Users → *Add user*, e-mail + mot de passe, *Auto Confirm User*).
3. **Vercel** : importer le projet avec **Root Directory = `plateforme`**, puis déclarer
   les variables d'environnement de `.env.example` :

   | Variable Vercel | Valeur (dans le `.env` du projet) |
   |---|---|
   | `NEXT_PUBLIC_SUPABASE_URL` | `SUPABASE_URL` |
   | `NEXT_PUBLIC_SUPABASE_ANON_KEY` | `SUPABASE_ANON_PUBLIC_KEY` |
   | `SUPABASE_SERVICE_ROLE_KEY` | `SUPABASE_SECRET_KEY` (jamais en `NEXT_PUBLIC_`) |

   Les fonctions tournent à Paris (`cdg1`, voir `vercel.json`), à côté de la base.
   Vercel déploie depuis un dépôt Git (GitHub…) ou avec `npx vercel` lancé dans ce dossier.

## Développement

```bash
cp .env.example .env.local   # puis renseigner les trois valeurs
npm install
npm run dev                  # http://localhost:3000
```

## Limites connues

- Un fichier compressé doit peser moins de 4,4 Mo (≈ 50 Mo non compressé). Le chemin
  complet est testé sur des exports d'environ 650 ko (cycle de 100 s) ; un cycle de
  plusieurs dizaines de minutes ferait un appel à la base très lourd, à tester avant.
- Tout utilisateur connecté peut déposer. Pour réserver le dépôt à certains comptes,
  ajouter une vérification de rôle dans `app/api/import/route.ts`.
