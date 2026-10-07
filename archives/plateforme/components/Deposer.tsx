"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import { useRouter } from "next/navigation";
import { torqueSignature, type Signature } from "@/lib/signature";
import { Trace } from "./Trace";

type Etat = "en attente" | "envoi" | "importé" | "doublon" | "erreur";
type Item = {
  id: number;
  file: File;
  etat: Etat;
  message: string;
  signature: Signature | null;
};

const SIMULTANES = 3;
let nextId = 1;

async function gzip(bytes: Uint8Array): Promise<Blob> {
  const stream = new Blob([bytes as BlobPart]).stream().pipeThrough(new CompressionStream("gzip"));
  return new Response(stream).blob();
}

function isExport(file: File) {
  return !file.name.startsWith(".") && /\.xls$/i.test(file.name);
}

// Parcourt un dossier glissé-déposé (et ses sous-dossiers)
async function filesFromEntry(entry: FileSystemEntry): Promise<File[]> {
  if (entry.isFile) {
    return new Promise((resolve) => (entry as FileSystemFileEntry).file((f) => resolve([f]), () => resolve([])));
  }
  const reader = (entry as FileSystemDirectoryEntry).createReader();
  const all: File[] = [];
  for (;;) {
    const batch = await new Promise<FileSystemEntry[]>((resolve) => reader.readEntries(resolve, () => resolve([])));
    if (!batch.length) break;
    for (const child of batch) all.push(...(await filesFromEntry(child)));
  }
  return all;
}

function taille(octets: number) {
  return octets < 1_000_000 ? `${Math.round(octets / 1000)} ko` : `${(octets / 1_000_000).toFixed(1)} Mo`;
}

export function Deposer() {
  const router = useRouter();
  const [items, setItems] = useState<Item[]>([]);
  const [survol, setSurvol] = useState(false);
  const [ignores, setIgnores] = useState(0);
  const enCours = useRef(new Set<number>());
  const inputFichiers = useRef<HTMLInputElement>(null);
  const inputDossier = useRef<HTMLInputElement>(null);

  const maj = useCallback((id: number, patch: Partial<Item>) => {
    setItems((list) => list.map((it) => (it.id === id ? { ...it, ...patch } : it)));
  }, []);

  const ajouter = useCallback((files: File[]) => {
    const retenus = files.filter(isExport);
    setIgnores((n) => n + files.length - retenus.length);
    setItems((list) => [
      ...list,
      ...retenus.map((file) => ({ id: nextId++, file, etat: "en attente" as Etat, message: "", signature: null })),
    ]);
  }, []);

  const envoyer = useCallback(
    async (item: Item) => {
      maj(item.id, { etat: "envoi", message: "" });
      try {
        const bytes = new Uint8Array(await item.file.arrayBuffer());
        maj(item.id, { signature: torqueSignature(bytes) });
        const res = await fetch("/api/import", {
          method: "POST",
          headers: { "content-type": "application/gzip", "x-file-name": encodeURIComponent(item.file.name) },
          body: await gzip(bytes),
        });
        const body = await res.json().catch(() => null);
        if (!body) throw new Error(`Réponse inattendue du serveur (HTTP ${res.status}).`);
        maj(item.id, { etat: body.status, message: body.message ?? "" });
      } catch (err) {
        maj(item.id, { etat: "erreur", message: (err as Error).message || "Envoi interrompu : vérifiez la connexion." });
      }
    },
    [maj],
  );

  // File d'attente : au plus SIMULTANES envois en parallèle
  useEffect(() => {
    const libres = SIMULTANES - enCours.current.size;
    if (libres <= 0) return;
    const suivants = items.filter((it) => it.etat === "en attente" && !enCours.current.has(it.id)).slice(0, libres);
    for (const item of suivants) {
      enCours.current.add(item.id);
      envoyer(item).finally(() => {
        enCours.current.delete(item.id);
        setItems((list) => [...list]); // relance la file
      });
    }
  }, [items, envoyer]);

  const total = items.length;
  const compte = (e: Etat) => items.filter((it) => it.etat === e).length;
  const termines = compte("importé") + compte("doublon") + compte("erreur");
  const actif = termines < total;

  // Historique rafraîchi à la fin de chaque lot
  const actifAvant = useRef(false);
  useEffect(() => {
    if (actifAvant.current && !actif) router.refresh();
    actifAvant.current = actif;
  }, [actif, router]);

  async function onDrop(e: React.DragEvent) {
    e.preventDefault();
    setSurvol(false);
    const entries = Array.from(e.dataTransfer.items)
      .map((i) => i.webkitGetAsEntry?.())
      .filter((x): x is FileSystemEntry => Boolean(x));
    if (entries.length) {
      const files = (await Promise.all(entries.map(filesFromEntry))).flat();
      ajouter(files);
    } else {
      ajouter(Array.from(e.dataTransfer.files));
    }
  }

  return (
    <section aria-labelledby="titre-depot">
      <div
        className={survol ? "plaque plaque-survol" : "plaque"}
        onDragOver={(e) => {
          e.preventDefault();
          setSurvol(true);
        }}
        onDragLeave={() => setSurvol(false)}
        onDrop={onDrop}
      >
        <h2 id="titre-depot">Déposez vos exports de cycle</h2>
        <p>
          Fichiers .xls un par un ou dossiers entiers. Chaque fichier est vérifié puis intégré en base ;
          un fichier déjà importé est reconnu et ignoré.
        </p>
        <div className="actions">
          <button type="button" className="bouton" onClick={() => inputFichiers.current?.click()}>
            Choisir des fichiers
          </button>
          <button type="button" className="bouton bouton-second" onClick={() => inputDossier.current?.click()}>
            Choisir un dossier
          </button>
        </div>
        <input
          ref={inputFichiers}
          type="file"
          accept=".xls"
          multiple
          hidden
          onChange={(e) => {
            ajouter(Array.from(e.target.files ?? []));
            e.target.value = "";
          }}
        />
        <input
          ref={inputDossier}
          type="file"
          hidden
          {...{ webkitdirectory: "" }}
          onChange={(e) => {
            ajouter(Array.from(e.target.files ?? []));
            e.target.value = "";
          }}
        />
      </div>

      {total > 0 && (
        <div className="file">
          <div className="bilan" aria-live="polite">
            <span>
              {termines} sur {total} traité{termines > 1 ? "s" : ""}
            </span>
            <span className="etat etat-importé">{compte("importé")} importé{compte("importé") > 1 ? "s" : ""}</span>
            <span className="etat etat-doublon">{compte("doublon")} déjà en base</span>
            <span className="etat etat-erreur">{compte("erreur")} en erreur</span>
            {ignores > 0 && <span className="discret">{ignores} ignoré{ignores > 1 ? "s" : ""} (pas .xls)</span>}
            <span className="bilan-actions">
              {compte("erreur") > 0 && !actif && (
                <button
                  type="button"
                  className="lien"
                  onClick={() =>
                    setItems((list) =>
                      list.map((it) => (it.etat === "erreur" ? { ...it, etat: "en attente", message: "" } : it)),
                    )
                  }
                >
                  Relancer les erreurs
                </button>
              )}
              {!actif && (
                <button
                  type="button"
                  className="lien"
                  onClick={() => {
                    setItems([]);
                    setIgnores(0);
                  }}
                >
                  Vider la liste
                </button>
              )}
            </span>
          </div>
          <div className="barre" role="progressbar" aria-valuemin={0} aria-valuemax={total} aria-valuenow={termines}>
            <div style={{ width: `${(termines / total) * 100}%` }} />
          </div>
          <ol className="liste">
            {items.map((it) => (
              <li key={it.id} className={`ligne ligne-${it.etat.replace(" ", "-")}`}>
                <span className="nom" title={it.file.name}>
                  {it.file.name}
                  <span className="discret">{taille(it.file.size)}</span>
                </span>
                <Trace signature={it.signature} muted={it.etat === "erreur"} />
                <span className={`etat etat-${it.etat.replace(" ", "-")}`}>{it.etat === "doublon" ? "déjà en base" : it.etat}</span>
                <span className="message">{it.message}</span>
              </li>
            ))}
          </ol>
        </div>
      )}
    </section>
  );
}
