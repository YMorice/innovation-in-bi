// Build Netlify : écrit config.js (URL et clé publique du projet Supabase) à partir des
// variables d'environnement du site. Lancé par netlify.toml ; aucune dépendance.
//
// config.js est servi publiquement avec la page : il ne doit contenir que la clé
// publique (publishable / anon). Le build échoue si une clé secrète est fournie.

const fs = require("fs");
const path = require("path");

// Valeur nettoyée : espaces et guillemets autour (fréquents en copiant-collant).
const clean = (v) => v.trim().replace(/^(['"])(.*)\1$/, "$2").trim();
const first = (names) => {
  for (const n of names) if (process.env[n] && clean(process.env[n])) return [n, clean(process.env[n])];
  return [null, ""];
};
const [urlVar, rawUrl] = first(["SUPABASE_URL", "NEXT_PUBLIC_SUPABASE_URL", "VITE_SUPABASE_URL", "PUBLIC_SUPABASE_URL"]);
const [keyVar, key] = first([
  "SUPABASE_KEY", "SUPABASE_PUBLISHABLE_KEY", "SUPABASE_ANON_KEY", "SUPABASE_ANON_PUBLIC_KEY",
  "NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY", "NEXT_PUBLIC_SUPABASE_ANON_KEY", "VITE_SUPABASE_ANON_KEY", "PUBLIC_SUPABASE_ANON_KEY",
]);

function fail(msg) {
  console.error("\n✗ config.js non généré : " + msg + "\n");
  process.exit(1);
}
if (!rawUrl) fail("variable SUPABASE_URL absente des variables d'environnement du site Netlify.");
if (!key) fail("variable SUPABASE_KEY (clé publishable ou anon) absente des variables d'environnement du site Netlify.");

// URL de l'API du projet, quelle que soit la forme collée : avec un chemin (/rest/v1),
// sans https://, adresse du tableau de bord Supabase, ou simple identifiant du projet.
function projectUrl(v) {
  if (/^postgres(ql)?:\/\//i.test(v)) {
    fail(urlVar + " contient une chaîne de connexion Postgres, pas l'URL de l'API : mettre " +
      "https://<identifiant>.supabase.co (Supabase > Project Settings > Data API > Project URL).");
  }
  if (/^[a-z0-9]{20}$/.test(v)) return "https://" + v + ".supabase.co";   // identifiant seul
  let u;
  try { u = new URL(/^[a-z]+:\/\//i.test(v) ? v : "https://" + v); } catch { return null; }
  const dash = /(^|\.)supabase\.com$/.test(u.hostname) && /\/project\/([a-z0-9]{20})/.exec(u.pathname);
  if (dash) return "https://" + dash[1] + ".supabase.co";                 // lien du tableau de bord
  if (u.protocol !== "https:" || u.username || u.password || !u.hostname.includes(".")) return null;
  return u.origin;                                                        // chemin et « / » final retirés
}
const url = projectUrl(rawUrl);
if (!url) {
  // l'URL n'est pas secrète : on l'affiche pour qu'on voie ce qui cloche (sauf identifiants éventuels)
  const shown = /@/.test(rawUrl) ? "(valeur masquée : elle contient un @)" : JSON.stringify(rawUrl);
  fail(urlVar + " vaut " + shown + " : attendu https://<identifiant>.supabase.co " +
    "(Supabase > Project Settings > Data API > Project URL).");
}
if (url !== rawUrl.replace(/\/+$/, "")) console.log("• " + urlVar + " interprétée comme " + url);

// Refus d'une clé secrète : elle donnerait tous les droits à quiconque ouvre la page.
if (key.startsWith("sb_secret_")) fail(keyVar + " est une clé secrète (sb_secret_…) : mettre la clé publishable (sb_publishable_…).");
if (key.startsWith("eyJ")) {
  let role = null;
  try {
    role = JSON.parse(Buffer.from(key.split(".")[1], "base64url").toString("utf8")).role;
  } catch {
    fail(keyVar + " n'est pas une clé lisible (JWT abîmé ?) : la recopier depuis Project Settings > API Keys.");
  }
  if (role !== "anon") fail(keyVar + " a le rôle « " + role + " » : mettre la clé anon (ou publishable), jamais service_role.");
}

const out = "// Généré au build Netlify par build-config.js : ne pas modifier.\n" +
  "window.SUPABASE_CONFIG = " + JSON.stringify({ url, key }) + ";\n";
fs.writeFileSync(path.join(__dirname, "config.js"), out);
console.log("✓ config.js généré (" + urlVar + ", " + keyVar + ")");
