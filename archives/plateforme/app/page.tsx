import { redirect } from "next/navigation";
import { Deposer } from "@/components/Deposer";
import { createClient } from "@/lib/supabase/server";

type ImportRow = {
  id: number;
  file_name: string;
  status: "importé" | "doublon" | "erreur";
  message: string | null;
  cycle_id: number | null;
  source: "web" | "cli";
  uploaded_by_email: string | null;
  created_at: string;
};

const quand = new Intl.DateTimeFormat("fr-FR", {
  dateStyle: "short",
  timeStyle: "short",
  timeZone: "Europe/Paris",
});

export default async function Accueil() {
  const supabase = await createClient();
  const { data: auth } = await supabase.auth.getUser();
  if (!auth.user) redirect("/login");

  const { data: autorise } = await supabase.rpc("est_autorise");
  if (autorise !== true) {
    return (
      <main className="connexion">
        <div className="connexion-carte">
          <h1>Accès refusé</h1>
          <p className="discret">Le compte {auth.user.email} n&apos;est pas autorisé sur ce projet.</p>
          <form action="/auth/deconnexion" method="post">
            <button type="submit" className="bouton">Se déconnecter</button>
          </form>
        </div>
      </main>
    );
  }

  const [{ data: historique, error }, { count: cycles }] = await Promise.all([
    supabase
      .from("import_file")
      .select("id, file_name, status, message, cycle_id, source, uploaded_by_email, created_at")
      .order("created_at", { ascending: false })
      .limit(50)
      .returns<ImportRow[]>(),
    supabase.from("cycle").select("id", { count: "estimated", head: true }),
  ]);

  return (
    <div className="page">
      <header className="entete">
        <div>
          <h1>Cycles de perçage</h1>
          <p className="discret">
            {cycles != null ? `${cycles.toLocaleString("fr-FR")} cycles en base` : "Intégration des exports en base"}
          </p>
        </div>
        <form action="/auth/deconnexion" method="post" className="compte">
          <span className="discret">{auth.user.email}</span>
          <button type="submit" className="lien">
            Se déconnecter
          </button>
        </form>
      </header>

      <main>
        <Deposer />

        <section className="historique" aria-labelledby="titre-historique">
          <h2 id="titre-historique">Derniers dépôts</h2>
          {error ? (
            <p className="alerte">Historique indisponible : {error.message}</p>
          ) : !historique?.length ? (
            <p className="discret">Aucun fichier déposé pour l&apos;instant. Déposez un premier export ci-dessus.</p>
          ) : (
            <div className="tableau">
              <table>
                <thead>
                  <tr>
                    <th scope="col">Déposé le</th>
                    <th scope="col">Fichier</th>
                    <th scope="col">Résultat</th>
                    <th scope="col">Détail</th>
                    <th scope="col">Par</th>
                  </tr>
                </thead>
                <tbody>
                  {historique.map((r) => (
                    <tr key={r.id}>
                      <td className="nombre">{quand.format(new Date(r.created_at))}</td>
                      <td className="nom-fichier">{r.file_name}</td>
                      <td>
                        <span className={`etat etat-${r.status}`}>{r.status === "doublon" ? "déjà en base" : r.status}</span>
                      </td>
                      <td className="message">
                        {r.cycle_id != null && r.status === "importé" ? `Cycle ${r.cycle_id} · ` : ""}
                        {r.message}
                      </td>
                      <td className="discret">{r.source === "cli" ? "script" : r.uploaded_by_email}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
        </section>
      </main>
    </div>
  );
}
