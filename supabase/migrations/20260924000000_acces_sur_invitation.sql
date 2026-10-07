-- Accès sur invitation : connexion Supabase Auth uniquement, aucune inscription.
--
--   * utilisateur_autorise : liste des e-mails autorisés, tenue à la main dans
--     l'éditeur SQL. Invisible depuis le web.
--   * trigger sur auth.users : toute création de compte (inscription publique,
--     ajout depuis le tableau de bord, invitation) est refusée si l'e-mail n'est pas
--     dans la liste. Filet de sécurité si « Allow new users to sign up » est
--     rallumé par erreur ou oublié sur un nouveau projet.
--   * est_autorise() : exigée par toutes les politiques de lecture. Retirer un
--     e-mail de la liste coupe l'accès aux données immédiatement, même avec une
--     session encore valide. Les connexions anonymes (sans e-mail) n'ont accès à rien.
--
-- Ajouter quelqu'un :
--   insert into public.utilisateur_autorise (email) values ('prenom.nom@exemple.fr');
--   puis Authentication > Users > Add user (e-mail + mot de passe).
-- Retirer quelqu'un :
--   delete from public.utilisateur_autorise where email = 'prenom.nom@exemple.fr';
--   puis supprimer l'utilisateur dans Authentication > Users.

create table public.utilisateur_autorise (
  email       text primary key check (email = lower(email)),
  commentaire text,
  ajoute_le   timestamptz not null default now()
);

alter table public.utilisateur_autorise enable row level security;
revoke all on public.utilisateur_autorise from anon, authenticated;

create or replace function public.est_autorise()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.utilisateur_autorise
     where email = lower(auth.jwt() ->> 'email')
  )
$$;

revoke execute on function public.est_autorise() from public, anon;
grant execute on function public.est_autorise() to authenticated, service_role;

-- ---------------------------------------------------------------- création de comptes

create or replace function public.refuser_compte_non_invite()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if (tg_op = 'INSERT' or new.email is distinct from old.email)
     and not exists (select 1 from public.utilisateur_autorise
                      where email = lower(new.email)) then
    raise exception 'Inscription fermée : % n''est pas dans utilisateur_autorise', new.email
      using errcode = 'insufficient_privilege';
  end if;
  return new;
end $$;

revoke execute on function public.refuser_compte_non_invite() from public, anon, authenticated;

create trigger refuser_compte_non_invite
  before insert or update of email on auth.users
  for each row execute function public.refuser_compte_non_invite();

-- ---------------------------------------------------------------- lecture des données
-- (select …) : évalué une fois par requête, pas une fois par ligne.

do $$
declare
  t text;
begin
  foreach t in array array['control_box', 'motor', 'head', 'program', 'program_step',
                           'stop_code_bit', 'cycle', 'cycle_step_result', 'cycle_sample',
                           'cycle_step_stats', 'import_file']
  loop
    execute format('drop policy %I on public.%I', 'lecture_' || t, t);
    execute format(
      'create policy %I on public.%I for select to authenticated using ((select public.est_autorise()))',
      'lecture_' || t, t);
  end loop;
end $$;
