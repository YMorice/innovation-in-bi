import { gunzipSync } from "node:zlib";
import { NextResponse, type NextRequest } from "next/server";
import { ParseError, parseExport, sha256Hex } from "@/lib/parser";
import { createAdminClient } from "@/lib/supabase/admin";
import { createClient } from "@/lib/supabase/server";

// Un appel = un fichier, envoyé compressé (gzip) par le navigateur pour rester
// sous la limite de 4,5 Mo des fonctions Vercel.
export const runtime = "nodejs";
export const maxDuration = 60; // région des fonctions : vercel.json (Paris, comme la base)

const MAX_COMPRESSED = 4_400_000;
const MAX_RAW = 80_000_000;

export type ImportStatus = "importé" | "doublon" | "erreur";
export type ImportResponse = {
  status: ImportStatus;
  message: string;
  cycle_id?: number | null;
};

function reply(body: ImportResponse, status = 200) {
  return NextResponse.json(body, { status });
}

export async function POST(request: NextRequest) {
  const supabase = await createClient();
  const { data: auth } = await supabase.auth.getUser();
  if (!auth.user) {
    return reply({ status: "erreur", message: "Session expirée : reconnectez-vous puis relancez." }, 401);
  }
  // L'écriture passe par la clé secrète, qui ignore les règles RLS : on vérifie ici
  // que le compte figure toujours dans utilisateur_autorise.
  const { data: autorise } = await supabase.rpc("est_autorise");
  if (autorise !== true) {
    return reply({ status: "erreur", message: "Ce compte n'est pas autorisé à déposer des exports." }, 403);
  }

  const fileName = decodeURIComponent(request.headers.get("x-file-name") ?? "sans-nom.xls").slice(0, 255);
  const compressed = new Uint8Array(await request.arrayBuffer());
  if (compressed.length > MAX_COMPRESSED) {
    return reply({ status: "erreur", message: "Fichier trop volumineux, même compressé (4,4 Mo au maximum)." }, 413);
  }

  let raw: Uint8Array;
  try {
    raw = new Uint8Array(gunzipSync(compressed, { maxOutputLength: MAX_RAW }));
  } catch {
    return reply({ status: "erreur", message: "Envoi illisible : le fichier n'a pas été reçu compressé." }, 400);
  }

  const admin = createAdminClient();
  const sha256 = sha256Hex(raw);
  let result: ImportResponse & { samples?: number };
  let isSynthetic = false;

  try {
    const doc = parseExport(raw, fileName);
    isSynthetic = doc.is_synthetic;
    const { data, error } = await admin.rpc("import_cycle", { p: doc });
    if (error) throw new Error(error.message);
    result = {
      status: data.status,
      cycle_id: data.cycle_id ?? null,
      message: data.status === "importé" ? `${data.samples} mesures` : data.message,
    };
  } catch (err) {
    const message = err instanceof ParseError
      ? `Format non reconnu : ${err.message}`
      : `Import refusé par la base : ${(err as Error).message}`;
    result = { status: "erreur", message };
  }

  // Copie du fichier brut (sauf doublon) pour pouvoir le réimporter plus tard
  let storagePath: string | null = null;
  if (result.status !== "doublon") {
    const folder = result.status === "importé" ? "importes" : "erreurs";
    const path = `${folder}/${sha256.slice(0, 2)}/${sha256}.xls.gz`;
    const { error } = await admin.storage
      .from("exports")
      .upload(path, compressed, { contentType: "application/gzip", upsert: true });
    if (!error) storagePath = path;
  }

  await admin.from("import_file").insert({
    file_name: fileName,
    sha256,
    size_bytes: raw.length,
    status: result.status,
    message: result.message,
    cycle_id: result.cycle_id ?? null,
    storage_path: storagePath,
    is_synthetic: isSynthetic,
    source: "web",
    uploaded_by: auth.user.id,
    uploaded_by_email: auth.user.email ?? null,
  });

  return reply(result, result.status === "erreur" ? 422 : 200);
}
