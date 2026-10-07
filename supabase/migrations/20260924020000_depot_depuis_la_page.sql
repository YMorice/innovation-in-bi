-- Dépôt des exports directement depuis la page web (app/index.html), sans serveur.
--
-- La page découpe le fichier dans le navigateur (même contrat que
-- scripts/charger_cycles.py) et appelle deposer_cycle avec la session de
-- l'utilisateur connecté. deposer_cycle vérifie que le compte est autorisé, appelle
-- import_cycle (qui reste réservée à la clé secrète) et note le dépôt dans
-- import_file. La clé secrète n'a donc jamais besoin d'être dans le navigateur.

create or replace function public.deposer_cycle(
  p              jsonb,     -- document découpé ; null si la page n'a pas pu lire le fichier
  p_file_name    text,
  p_sha256       text,
  p_size_bytes   int,
  p_storage_path text default null,
  p_erreur       text default null   -- erreur de lecture côté page, journalisée telle quelle
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  r jsonb;
begin
  if not public.est_autorise() then
    raise exception 'Compte non autorisé' using errcode = 'insufficient_privilege';
  end if;

  if p_erreur is not null or p is null then
    r := jsonb_build_object('status', 'erreur', 'message', coalesce(p_erreur, 'fichier vide'));
  else
    begin
      r := public.import_cycle(p);
    exception when others then
      -- l'import est annulé en entier ; le dépôt est quand même journalisé
      r := jsonb_build_object('status', 'erreur', 'message', 'Import refusé par la base : ' || sqlerrm);
    end;
  end if;

  insert into public.import_file
         (file_name, sha256, size_bytes, status, message, cycle_id, storage_path,
          is_synthetic, source, uploaded_by, uploaded_by_email)
  values (left(p_file_name, 255), p_sha256, p_size_bytes, r->>'status',
          case when r->>'status' = 'importé' then (r->>'samples') || ' mesures' else r->>'message' end,
          (r->>'cycle_id')::bigint, p_storage_path,
          coalesce((p->>'is_synthetic')::boolean, false), 'web',
          auth.uid(), auth.jwt() ->> 'email');
  return r;
end $$;

revoke execute on function public.deposer_cycle(jsonb, text, text, int, text, text) from public, anon;
grant execute on function public.deposer_cycle(jsonb, text, text, int, text, text) to authenticated, service_role;

-- Copie brute (compressée) de chaque fichier dans le bucket privé "exports" :
-- un compte autorisé peut y ajouter, personne ne peut lire, modifier ni supprimer
-- depuis le web.
do $$
begin
  if to_regclass('storage.objects') is not null then
    create policy depot_exports on storage.objects for insert to authenticated
      with check (bucket_id = 'exports' and (select public.est_autorise()));
  end if;
end $$;
