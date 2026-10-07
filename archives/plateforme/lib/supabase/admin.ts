import "server-only";
import { createClient } from "@supabase/supabase-js";

// Client avec la clé secrète : écrit en base et dans le stockage sans RLS.
// Uniquement côté serveur, après vérification de la session de l'utilisateur.
export function createAdminClient() {
  const key = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!key) throw new Error("SUPABASE_SERVICE_ROLE_KEY n'est pas configurée");
  return createClient(process.env.NEXT_PUBLIC_SUPABASE_URL!, key, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
}
