"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";

export default function Connexion() {
  const router = useRouter();
  const [email, setEmail] = useState("");
  const [motDePasse, setMotDePasse] = useState("");
  const [erreur, setErreur] = useState<string | null>(null);
  const [envoi, setEnvoi] = useState(false);

  async function onSubmit(e: React.FormEvent) {
    e.preventDefault();
    setEnvoi(true);
    setErreur(null);
    const { error } = await createClient().auth.signInWithPassword({ email, password: motDePasse });
    setEnvoi(false);
    if (error) {
      setErreur(
        error.message === "Invalid login credentials"
          ? "E-mail ou mot de passe incorrect."
          : `Connexion impossible : ${error.message}`,
      );
      return;
    }
    router.replace("/");
    router.refresh();
  }

  return (
    <main className="connexion">
      <form onSubmit={onSubmit} className="connexion-carte">
        <h1>Cycles de perçage</h1>
        <p className="discret">Connectez-vous pour déposer des exports.</p>
        <label>
          E-mail
          <input type="email" autoComplete="email" required value={email} onChange={(e) => setEmail(e.target.value)} />
        </label>
        <label>
          Mot de passe
          <input
            type="password"
            autoComplete="current-password"
            required
            value={motDePasse}
            onChange={(e) => setMotDePasse(e.target.value)}
          />
        </label>
        {erreur && (
          <p className="alerte" role="alert">
            {erreur}
          </p>
        )}
        <button type="submit" className="bouton" disabled={envoi}>
          {envoi ? "Connexion…" : "Se connecter"}
        </button>
        <p className="discret petit">Pas de compte ? Demandez à l&apos;administrateur du projet de vous en créer un.</p>
      </form>
    </main>
  );
}
