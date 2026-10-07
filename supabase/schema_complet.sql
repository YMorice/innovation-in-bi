-- =====================================================================================
-- Schéma complet « cycles de perçage » : base neuve, en un seul passage.
--
-- Équivaut aux migrations de supabase/migrations/ appliquées dans l'ordre, fusionnées
-- (is_synthetic directement dans cycle, vues et politiques définies une seule fois).
-- À lancer UNE fois, dans l'éditeur SQL d'un projet Supabase vide.
-- Tout est dans une transaction : en cas d'erreur, rien n'est créé.
--
-- Accès : connexion Supabase Auth uniquement, sur invitation. Aucune inscription
-- possible, aucune donnée lisible sans compte autorisé.
--
-- Après exécution, sur le nouveau projet :
--   1. Authentication > Sign In / Providers : décocher « Allow new users to sign up »
--      et laisser « Allow anonymous sign-ins » décoché. (Le trigger ci-dessous
--      bloque de toute façon les e-mails non invités ; c'est la seconde barrière.)
--   2. Pour chaque personne : ajouter son e-mail (voir plus bas, utilisateur_autorise),
--      puis Authentication > Users > Add user, avec « Auto Confirm User ».
--   3. Renseigner stop_code_bit (signification des bits du Stop Code) si connue.
--   4. Plateforme Vercel : URL, clé publique et clé secrète du nouveau projet.
--   5. CLI : même URL / clé secrète dans .env, puis ingestion/charger_cycles.py.
-- =====================================================================================

begin;

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

-- Stockage des exports de cycles de perçage (un fichier = un cycle).
--
-- Modèle en étoile, dans le schéma public (exposé à l'API web de Supabase) :
--   dimensions  : control_box, motor, head, program (+ program_step), stop_code_bit
--   faits       : cycle (1 ligne / fichier), cycle_step_result (1 ligne / étape),
--                 cycle_sample (1 ligne / mesure à sample_rate_hz)
--   analyse     : cycle_step_stats (agrégats par cycle et étape, calculés à l'import),
--                 vues v_cycle, v_cycle_step et v_cycle_sample.
--
-- Choix pour la montée en charge :
--   * les programmes sont dédupliqués par empreinte (content_hash) : des milliers de
--     cycles lancés avec le même Pset partagent une seule ligne program ;
--   * cycle_sample (~10 000 lignes par cycle) est partitionnée par tranches de
--     10 000 cycles (RANGE sur cycle_id, créées à la demande par
--     ensure_cycle_sample_partition). Les identifiants croissent avec l'import :
--     les vieilles tranches peuvent être détachées ou archivées sans toucher aux
--     récentes, et une requête sur un cycle ne lit qu'une partition ;
--   * les mesures sont en real (4 octets) : la précision de l'export est de 3 décimales ;
--   * les compteurs relevés au moment du cycle (heures de fonctionnement, compteurs de
--     tête, firmware) sont stockés sur le cycle, pas sur la dimension, pour garder
--     l'historique ;
--   * une colonne jsonb "extra" sur chaque table reçoit les champs qu'une future
--     version d'export ajouterait, sans migration préalable ;
--   * un fichier déjà importé (même empreinte SHA-256) ou un cycle déjà connu
--     (même boîtier + Drilling Cycle ID) est ignoré : l'import peut être rejoué.
--
-- Accès : lecture seule depuis le web pour les utilisateurs connectés (rôle
-- authenticated). L'écriture passe uniquement par la clé secrète ou une connexion
-- directe à la base (script ingestion/charger_cycles.py).

-- ---------------------------------------------------------------- dimensions

create table public.control_box (
  id                 bigint generated always as identity primary key,
  box_sn             text not null unique,
  box_name           text,
  box_type           text,
  box_stse           text,
  customer_info      text,
  production_date    date,
  power_supply_limit numeric,
  lub_pump_coef      numeric,
  extra              jsonb not null default '{}'
);

create table public.motor (
  id               bigint generated always as identity primary key,
  motor_name       text not null,
  motor_type       text,
  motor_stse       text,
  motor_sn         text not null,
  m2_ratio         numeric,
  m1_cw_ratio      numeric,
  m1_ccw_ratio     numeric,
  winch_limit      numeric,
  extra            jsonb not null default '{}',
  unique (motor_name, motor_sn)
);

create table public.head (
  id               bigint generated always as identity primary key,
  head_tag_uid     text not null unique,
  head_name        text,
  head_type        text,
  m1_ratio         numeric,
  m2_ratio         numeric,
  customer_info    text,
  extra            jsonb not null default '{}'
);

-- Programme = Pset + paramètres de cycle + étapes. Dédupliqué par empreinte.
create table public.program (
  id                          bigint generated always as identity primary key,
  content_hash                text not null unique,
  pset_type                   text,
  pset_nb                     int,
  pset_version                int,
  max_cycles_limit_1          int,
  max_cycles_limit_2          int,
  cc_pressure                 numeric,
  max_stroke_mm               numeric,
  vacuum_delay_ms             numeric,
  vacuum_flow_min_ms          numeric,
  retract_rotation_speed_rpm  numeric,
  retract_feed_ms             numeric,
  disable_abort               boolean,
  comment                     text,
  tool_breakage_on            boolean,
  tool_breakage_dep_mm        numeric,
  tool_breakage_thrust_a      numeric,
  tool_breakage_torque_a      numeric,
  lub_preload_time_s          numeric,
  lub_preload_lub_air         numeric,
  lub_preload_lub_flow        numeric,
  lub_preload_timeout_s       numeric,
  extra                       jsonb not null default '{}',
  created_at                  timestamptz not null default now()
);

create index program_pset_idx on public.program (pset_type, pset_nb, pset_version);

create table public.program_step (
  program_id         bigint not null references public.program (id) on delete cascade,
  step_nb            smallint not null,
  step_on            boolean,
  stroke_mm          numeric,
  rpm                numeric,
  feed_mm_s          numeric,
  feed_mm_tr         numeric,          -- "Inf" dans l'export => NULL
  thrust_max_a       numeric,
  torque_max_a       numeric,
  thrust_min_a       numeric,
  torque_min_a       numeric,
  thrust_safety_a    numeric,
  torque_safety_a    numeric,
  gap_mm             numeric,
  peck_nb            numeric,
  delay_ms           numeric,
  stroke_limit_a     numeric,
  thrust_limit_a     numeric,
  torque_limit_a     numeric,
  lub_air            numeric,
  lub_flow           numeric,
  vacuum             numeric,
  material           numeric,
  extra              jsonb not null default '{}',
  primary key (program_id, step_nb)
);

-- Signification des bits du Stop Code (1, 2048… dans l'export). À renseigner à
-- partir de la documentation constructeur ; v_cycle_step décode automatiquement.
create table public.stop_code_bit (
  bit        smallint primary key check (bit between 0 and 30),
  label      text not null,
  is_fault   boolean not null default false
);

-- ---------------------------------------------------------------- faits

create table public.cycle (
  id                        bigint generated always as identity primary key,
  drilling_cycle_id         bigint not null,           -- "Drilling Cycle ID" de l'export
  started_at                timestamp not null,        -- heure locale du boîtier
  file_version              int,
  sample_rate_hz            int not null check (sample_rate_hz > 0),
  box_id                    bigint not null references public.control_box (id),
  motor_id                  bigint references public.motor (id),
  head_id                   bigint references public.head (id),
  program_id                bigint references public.program (id),
  -- relevés au moment du cycle
  box_release               text,
  box_firmware_version      text,
  box_maintenance_date      date,
  box_operation_time        bigint,
  pset_default_selection    boolean,
  motor_operation_time      bigint,
  head_global_counter       int,
  head_local_counter_1      int,
  head_local_counter_2      int,
  -- résultats
  cycle_time_s              numeric,
  distance_mm               numeric,
  cycle_ok                  boolean,
  -- traçabilité
  source_file               text,
  source_sha256             text unique,
  imported_at               timestamptz not null default now(),
  extra                     jsonb not null default '{}',
  is_synthetic              boolean not null default false,  -- généré par synthetique/generer.py
  unique (box_id, drilling_cycle_id)
);

create index cycle_started_at_idx on public.cycle (started_at);
create index cycle_head_idx       on public.cycle (head_id, head_global_counter);
create index cycle_program_idx    on public.cycle (program_id);
create index cycle_motor_idx      on public.cycle (motor_id);
create index cycle_synthetic_idx  on public.cycle (is_synthetic) where is_synthetic;

create table public.cycle_step_result (
  cycle_id           bigint not null references public.cycle (id) on delete cascade,
  step_nb            smallint not null,
  stop_code          int,             -- champ de bits, voir stop_code_bit
  duration_s         numeric,
  distance_m1        numeric,
  distance_m2        numeric,
  m1_max_amp         numeric,
  m2_max_amp         numeric,
  m1_no_load_amp     numeric,
  m2_no_load_amp     numeric,
  gap_max_mm         numeric,
  extra              jsonb not null default '{}',
  primary key (cycle_id, step_nb)
);

-- Série temporelle brute. t = sample_idx / cycle.sample_rate_hz.
create table public.cycle_sample (
  cycle_id            bigint   not null,
  sample_idx          int      not null,
  position_mm         real,
  i_torque_a          real,
  i_thrust_a          real,
  i_torque_empty_a    real,
  i_thrust_empty_a    real,
  step_nb             smallint,
  stop_code           int,
  mem_torque_min_a    real,
  mem_thrust_min_a    real,
  torque_power_w      real,
  gap_length_mm       real,
  primary key (cycle_id, sample_idx),
  foreign key (cycle_id) references public.cycle (id) on delete cascade
) partition by range (cycle_id);

-- Crée (si besoin) la partition de cycle_sample qui recevra p_cycle_id.
-- À appeler avant d'insérer les mesures d'un nouveau cycle. Les partitions sont
-- verrouillées (RLS sans politique, aucun droit web) : le web lit cycle_sample,
-- dont la politique s'applique à toutes les partitions.
create or replace function public.ensure_cycle_sample_partition(p_cycle_id bigint)
returns text
language plpgsql
security definer   -- la partition est créée par le propriétaire, quel que soit l'appelant
set search_path = ''
as $$
declare
  v_block constant bigint := 10000;
  v_from  bigint := (p_cycle_id / v_block) * v_block;
  v_name  text   := format('cycle_sample_%s', lpad((p_cycle_id / v_block)::text, 6, '0'));
begin
  if to_regclass('public.' || v_name) is null then
    -- deux imports simultanés ne doivent pas créer la même partition
    perform pg_advisory_xact_lock(hashtext('public.' || v_name));
    if to_regclass('public.' || v_name) is null then
      execute format(
        'create table public.%I partition of public.cycle_sample
           for values from (%s) to (%s)', v_name, v_from, v_from + v_block);
      execute format('alter table public.%I enable row level security', v_name);
      execute format('revoke all on public.%I from anon, authenticated', v_name);
    end if;
  end if;
  return v_name;
end $$;

-- Agrégats par cycle et par étape : la plupart des analyses inter-cycles
-- (usure d'outil, dérive, comparaison de programmes) lisent cette table
-- au lieu de balayer les mesures brutes. Elle permet aussi d'archiver les
-- vieilles partitions de cycle_sample sans perdre les indicateurs.
create table public.cycle_step_stats (
  cycle_id            bigint not null references public.cycle (id) on delete cascade,
  step_nb             smallint not null,
  n_samples           int not null,
  duration_s          numeric,
  position_start_mm   real,
  position_end_mm     real,
  torque_avg_a        real,
  torque_max_a        real,
  torque_p95_a        real,
  thrust_avg_a        real,
  thrust_max_a        real,
  thrust_p95_a        real,
  torque_power_avg_w  real,
  torque_power_max_w  real,
  energy_j            real,           -- somme(puissance) / sample_rate
  gap_max_mm          real,
  primary key (cycle_id, step_nb)
);

create or replace function public.refresh_cycle_step_stats(p_cycle_id bigint)
returns void
language sql
set search_path = ''
as $$
  delete from public.cycle_step_stats where cycle_id = p_cycle_id;
  insert into public.cycle_step_stats
  select s.cycle_id,
         s.step_nb,
         count(*),
         count(*)::numeric / c.sample_rate_hz,
         (array_agg(s.position_mm order by s.sample_idx))[1],
         (array_agg(s.position_mm order by s.sample_idx desc))[1],
         avg(s.i_torque_a),
         max(s.i_torque_a),
         percentile_cont(0.95) within group (order by s.i_torque_a),
         avg(s.i_thrust_a),
         max(s.i_thrust_a),
         percentile_cont(0.95) within group (order by s.i_thrust_a),
         avg(s.torque_power_w),
         max(s.torque_power_w),
         sum(s.torque_power_w) / c.sample_rate_hz,
         max(s.gap_length_mm)
    from public.cycle_sample s
    join public.cycle c on c.id = s.cycle_id
   where s.cycle_id = p_cycle_id
   group by s.cycle_id, s.step_nb, c.sample_rate_hz;
$$;

-- ---------------------------------------------------------------- vues d'analyse

create view public.v_cycle with (security_invoker = true) as
select c.id                  as cycle_id,
       c.drilling_cycle_id,
       c.started_at,
       c.started_at::date    as cycle_date,
       c.cycle_ok,
       c.cycle_time_s,
       c.distance_mm,
       b.box_sn, b.box_name, c.box_firmware_version,
       m.motor_name, m.motor_sn,
       h.head_tag_uid, h.head_name, h.head_type,
       c.head_global_counter, c.head_local_counter_1, c.head_local_counter_2,
       p.id                  as program_id,
       p.pset_type, p.pset_nb, p.pset_version,
       c.source_file,
       c.is_synthetic
  from public.cycle c
  join public.control_box b on b.id = c.box_id
  left join public.motor   m on m.id = c.motor_id
  left join public.head    h on h.id = c.head_id
  left join public.program p on p.id = c.program_id;

-- Une ligne par cycle et par étape : consigne (programme) face au réalisé
-- (résultats de l'export et agrégats calculés).
create view public.v_cycle_step with (security_invoker = true) as
select c.id                  as cycle_id,
       c.started_at,
       c.box_id, c.head_id, c.program_id,
       c.head_global_counter,
       r.step_nb,
       -- consigne
       ps.rpm                as set_rpm,
       ps.feed_mm_s          as set_feed_mm_s,
       ps.feed_mm_tr         as set_feed_mm_tr,
       ps.stroke_mm          as set_stroke_mm,
       ps.torque_max_a       as set_torque_max_a,
       ps.thrust_max_a       as set_thrust_max_a,
       ps.torque_min_a       as set_torque_min_a,
       ps.gap_mm             as set_gap_mm,
       -- réalisé
       r.stop_code,
       (select array_agg(b.label order by b.bit)
          from public.stop_code_bit b
         where r.stop_code & (1 << b.bit) <> 0) as stop_labels,
       r.duration_s,
       r.distance_m2,
       r.m1_max_amp, r.m2_max_amp,
       r.m1_no_load_amp, r.m2_no_load_amp,
       r.gap_max_mm,
       st.torque_avg_a, st.torque_max_a, st.torque_p95_a,
       st.thrust_avg_a, st.thrust_max_a, st.thrust_p95_a,
       st.torque_power_avg_w, st.energy_j,
       c.is_synthetic
  from public.cycle c
  join public.cycle_step_result r   on r.cycle_id = c.id
  left join public.program_step ps  on ps.program_id = c.program_id and ps.step_nb = r.step_nb
  left join public.cycle_step_stats st on st.cycle_id = c.id and st.step_nb = r.step_nb;

create view public.v_cycle_sample with (security_invoker = true) as
select s.*,
       s.sample_idx::double precision / c.sample_rate_hz as t_s,
       c.started_at + make_interval(secs => s.sample_idx::double precision / c.sample_rate_hz) as ts
  from public.cycle_sample s
  join public.cycle c on c.id = s.cycle_id;

-- ---------------------------------------------------------------- accès web
-- RLS sur toutes les tables ; une seule politique : lecture pour les utilisateurs
-- connectés dont l'e-mail est dans utilisateur_autorise (voir en tête de script). Aucune politique d'écriture : l'API web (clé publique) ne peut rien
-- modifier. Les vues sont en security_invoker, elles héritent de ces règles.

do $$
declare
  t text;
begin
  foreach t in array array['control_box', 'motor', 'head', 'program', 'program_step',
                           'stop_code_bit', 'cycle', 'cycle_step_result', 'cycle_sample',
                           'cycle_step_stats']
  loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon, authenticated', t);
    execute format('grant select on public.%I to authenticated', t);
    execute format(
      'create policy %I on public.%I for select to authenticated using ((select public.est_autorise()))',
      'lecture_' || t, t);
  end loop;
end $$;

revoke all on public.v_cycle, public.v_cycle_step, public.v_cycle_sample from anon, authenticated;
grant select on public.v_cycle, public.v_cycle_step, public.v_cycle_sample to authenticated;

-- fonctions d'import : réservées au script de chargement
revoke execute on function public.refresh_cycle_step_stats(bigint)       from public, anon, authenticated;
revoke execute on function public.ensure_cycle_sample_partition(bigint)  from public, anon, authenticated;

-- ---------------------------------------------------------------- journal des dépôts

create table public.import_file (
  id                 bigint generated always as identity primary key,
  file_name          text not null,
  sha256             text,
  size_bytes         int,
  status             text not null check (status in ('importé', 'doublon', 'erreur')),
  message            text,
  cycle_id           bigint references public.cycle (id) on delete set null,
  storage_path       text,
  is_synthetic       boolean not null default false,
  source             text not null default 'web' check (source in ('web', 'cli')),
  uploaded_by        uuid,
  uploaded_by_email  text,
  created_at         timestamptz not null default now()
);

create index import_file_created_idx on public.import_file (created_at desc);
create index import_file_sha_idx     on public.import_file (sha256);

alter table public.import_file enable row level security;
revoke all on public.import_file from anon, authenticated;
grant select on public.import_file to authenticated;
create policy lecture_import_file on public.import_file for select to authenticated using ((select public.est_autorise()));

-- ---------------------------------------------------------------- import

-- tableau json de nombres (null autorisés) -> float8[], dans l'ordre
create or replace function public.jsonb_float8_array(j jsonb)
returns float8[]
language sql
immutable
set search_path = ''
as $$
  select array_agg(e::float8 order by o)
    from jsonb_array_elements_text(j) with ordinality as x(e, o)
$$;

create or replace function public.import_cycle(p jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_box       bigint;
  v_motor     bigint;
  v_head      bigint;
  v_program   bigint;
  v_cycle     bigint;
  v_hash      text;
  v_samples   int;
  v_existing  bigint;
  s           jsonb := p->'samples';
begin
  select id into v_existing from public.cycle where source_sha256 = p->>'source_sha256';
  if v_existing is not null then
    return jsonb_build_object('status', 'doublon', 'cycle_id', v_existing,
                              'message', 'fichier déjà importé');
  end if;

  -- dimensions : la dernière valeur importée fait foi
  insert into public.control_box as t
         (box_sn, box_name, box_type, box_stse, customer_info, production_date,
          power_supply_limit, lub_pump_coef, extra)
  select r.box_sn, r.box_name, r.box_type, r.box_stse, r.customer_info, r.production_date,
         r.power_supply_limit, r.lub_pump_coef, coalesce(r.extra, '{}')
    from jsonb_populate_record(null::public.control_box, p->'box') r
  on conflict (box_sn) do update
     set box_name = excluded.box_name, box_type = excluded.box_type,
         box_stse = excluded.box_stse, customer_info = excluded.customer_info,
         production_date = excluded.production_date,
         power_supply_limit = excluded.power_supply_limit,
         lub_pump_coef = excluded.lub_pump_coef, extra = excluded.extra
  returning id into v_box;

  if jsonb_typeof(p->'motor') = 'object' then
    insert into public.motor as t
           (motor_name, motor_type, motor_stse, motor_sn, m2_ratio, m1_cw_ratio,
            m1_ccw_ratio, winch_limit, extra)
    select r.motor_name, r.motor_type, r.motor_stse, coalesce(r.motor_sn, ''), r.m2_ratio,
           r.m1_cw_ratio, r.m1_ccw_ratio, r.winch_limit, coalesce(r.extra, '{}')
      from jsonb_populate_record(null::public.motor, p->'motor') r
    on conflict (motor_name, motor_sn) do update
       set motor_type = excluded.motor_type, motor_stse = excluded.motor_stse,
           m2_ratio = excluded.m2_ratio, m1_cw_ratio = excluded.m1_cw_ratio,
           m1_ccw_ratio = excluded.m1_ccw_ratio, winch_limit = excluded.winch_limit,
           extra = excluded.extra
    returning id into v_motor;
  end if;

  if jsonb_typeof(p->'head') = 'object' then
    insert into public.head as t
           (head_tag_uid, head_name, head_type, m1_ratio, m2_ratio, customer_info, extra)
    select r.head_tag_uid, r.head_name, r.head_type, r.m1_ratio, r.m2_ratio,
           r.customer_info, coalesce(r.extra, '{}')
      from jsonb_populate_record(null::public.head, p->'head') r
    on conflict (head_tag_uid) do update
       set head_name = excluded.head_name, head_type = excluded.head_type,
           m1_ratio = excluded.m1_ratio, m2_ratio = excluded.m2_ratio,
           customer_info = excluded.customer_info, extra = excluded.extra
    returning id into v_head;
  end if;

  -- programme, dédupliqué par empreinte de son contenu (paramètres + étapes)
  v_hash := encode(sha256(convert_to((p->'program')::text, 'UTF8')), 'hex');
  insert into public.program
         (content_hash, pset_type, pset_nb, pset_version, max_cycles_limit_1,
          max_cycles_limit_2, cc_pressure, max_stroke_mm, vacuum_delay_ms,
          vacuum_flow_min_ms, retract_rotation_speed_rpm, retract_feed_ms, disable_abort,
          comment, tool_breakage_on, tool_breakage_dep_mm, tool_breakage_thrust_a,
          tool_breakage_torque_a, lub_preload_time_s, lub_preload_lub_air,
          lub_preload_lub_flow, lub_preload_timeout_s, extra)
  select v_hash, r.pset_type, r.pset_nb, r.pset_version, r.max_cycles_limit_1,
         r.max_cycles_limit_2, r.cc_pressure, r.max_stroke_mm, r.vacuum_delay_ms,
         r.vacuum_flow_min_ms, r.retract_rotation_speed_rpm, r.retract_feed_ms,
         r.disable_abort, r.comment, r.tool_breakage_on, r.tool_breakage_dep_mm,
         r.tool_breakage_thrust_a, r.tool_breakage_torque_a, r.lub_preload_time_s,
         r.lub_preload_lub_air, r.lub_preload_lub_flow, r.lub_preload_timeout_s,
         coalesce(r.extra, '{}')
    from jsonb_populate_record(null::public.program, (p->'program') - 'steps') r
  on conflict (content_hash) do nothing
  returning id into v_program;

  if v_program is null then
    select id into v_program from public.program where content_hash = v_hash;
  else
    insert into public.program_step
           (program_id, step_nb, step_on, stroke_mm, rpm, feed_mm_s, feed_mm_tr,
            thrust_max_a, torque_max_a, thrust_min_a, torque_min_a, thrust_safety_a,
            torque_safety_a, gap_mm, peck_nb, delay_ms, stroke_limit_a, thrust_limit_a,
            torque_limit_a, lub_air, lub_flow, vacuum, material, extra)
    select v_program, r.step_nb, r.step_on, r.stroke_mm, r.rpm, r.feed_mm_s, r.feed_mm_tr,
           r.thrust_max_a, r.torque_max_a, r.thrust_min_a, r.torque_min_a, r.thrust_safety_a,
           r.torque_safety_a, r.gap_mm, r.peck_nb, r.delay_ms, r.stroke_limit_a,
           r.thrust_limit_a, r.torque_limit_a, r.lub_air, r.lub_flow, r.vacuum, r.material,
           coalesce(r.extra, '{}')
      from jsonb_populate_recordset(null::public.program_step, p->'program'->'steps') r;
  end if;

  -- cycle
  insert into public.cycle
         (drilling_cycle_id, started_at, file_version, sample_rate_hz, box_id, motor_id,
          head_id, program_id, box_release, box_firmware_version, box_maintenance_date,
          box_operation_time, pset_default_selection, motor_operation_time,
          head_global_counter, head_local_counter_1, head_local_counter_2, cycle_time_s,
          distance_mm, cycle_ok, source_file, source_sha256, is_synthetic, extra)
  select r.drilling_cycle_id, r.started_at, r.file_version, r.sample_rate_hz, v_box, v_motor,
         v_head, v_program, r.box_release, r.box_firmware_version, r.box_maintenance_date,
         r.box_operation_time, r.pset_default_selection, r.motor_operation_time,
         r.head_global_counter, r.head_local_counter_1, r.head_local_counter_2,
         r.cycle_time_s, r.distance_mm, r.cycle_ok, r.source_file, r.source_sha256,
         coalesce(r.is_synthetic, false), coalesce(r.extra, '{}')
    from jsonb_populate_record(null::public.cycle, p) r
  on conflict (box_id, drilling_cycle_id) do nothing
  returning id into v_cycle;

  if v_cycle is null then
    select id into v_existing from public.cycle
     where box_id = v_box and drilling_cycle_id = (p->>'drilling_cycle_id')::bigint;
    return jsonb_build_object('status', 'doublon', 'cycle_id', v_existing,
                              'message', 'cycle déjà connu (même boîtier et Drilling Cycle ID)');
  end if;

  insert into public.cycle_step_result
         (cycle_id, step_nb, stop_code, duration_s, distance_m1, distance_m2, m1_max_amp,
          m2_max_amp, m1_no_load_amp, m2_no_load_amp, gap_max_mm, extra)
  select v_cycle, r.step_nb, r.stop_code, r.duration_s, r.distance_m1, r.distance_m2,
         r.m1_max_amp, r.m2_max_amp, r.m1_no_load_amp, r.m2_no_load_amp, r.gap_max_mm,
         coalesce(r.extra, '{}')
    from jsonb_populate_recordset(null::public.cycle_step_result, p->'step_results') r;

  -- mesures : un tableau par colonne, index = position dans le tableau
  perform public.ensure_cycle_sample_partition(v_cycle);
  insert into public.cycle_sample
         (cycle_id, sample_idx, position_mm, i_torque_a, i_thrust_a, i_torque_empty_a,
          i_thrust_empty_a, step_nb, stop_code, mem_torque_min_a, mem_thrust_min_a,
          torque_power_w, gap_length_mm)
  select v_cycle, (t.n - 1)::int, t.a::real, t.b::real, t.c::real, t.d::real, t.e::real,
         t.f::smallint, t.g::int, t.h::real, t.i::real, t.j::real, t.k::real
    from unnest(public.jsonb_float8_array(s->'position_mm'),
                public.jsonb_float8_array(s->'i_torque_a'),
                public.jsonb_float8_array(s->'i_thrust_a'),
                public.jsonb_float8_array(s->'i_torque_empty_a'),
                public.jsonb_float8_array(s->'i_thrust_empty_a'),
                public.jsonb_float8_array(s->'step_nb'),
                public.jsonb_float8_array(s->'stop_code'),
                public.jsonb_float8_array(s->'mem_torque_min_a'),
                public.jsonb_float8_array(s->'mem_thrust_min_a'),
                public.jsonb_float8_array(s->'torque_power_w'),
                public.jsonb_float8_array(s->'gap_length_mm'))
         with ordinality as t(a, b, c, d, e, f, g, h, i, j, k, n);
  get diagnostics v_samples = row_count;

  perform public.refresh_cycle_step_stats(v_cycle);

  return jsonb_build_object('status', 'importé', 'cycle_id', v_cycle, 'samples', v_samples);
exception
  when unique_violation then
    -- même fichier ou même cycle importé en parallèle par un autre dépôt ;
    -- tout autre doublon (deux étapes de même numéro…) est une vraie erreur
    declare
      v_constraint text;
    begin
      get stacked diagnostics v_constraint = constraint_name;
      if v_constraint in ('cycle_source_sha256_key', 'cycle_box_id_drilling_cycle_id_key') then
        return jsonb_build_object('status', 'doublon',
                                  'message', 'importé en parallèle par un autre dépôt');
      end if;
      raise exception using errcode = 'unique_violation', message = sqlerrm;
    end;
end $$;

-- Supprime toutes les données synthétiques (cycles, mesures, journal) et les
-- équipements et programmes qui ne servent plus. À lancer avant de passer aux
-- vraies données : select public.purge_synthetic();
create or replace function public.purge_synthetic()
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_cycles int;
begin
  delete from public.import_file where is_synthetic;
  delete from public.cycle where is_synthetic;
  get diagnostics v_cycles = row_count;
  delete from public.program p where not exists (select 1 from public.cycle c where c.program_id = p.id);
  delete from public.head h where not exists (select 1 from public.cycle c where c.head_id = h.id);
  delete from public.motor m where not exists (select 1 from public.cycle c where c.motor_id = m.id);
  delete from public.control_box b where not exists (select 1 from public.cycle c where c.box_id = b.id);
  return jsonb_build_object('cycles_supprimes', v_cycles);
end $$;

-- ---------------------------------------------------------------- droits
-- Fonctions d'écriture : clé secrète uniquement (service_role), jamais le navigateur.

revoke execute on function public.jsonb_float8_array(jsonb)             from public, anon, authenticated;
revoke execute on function public.import_cycle(jsonb)                   from public, anon, authenticated;
revoke execute on function public.purge_synthetic()                     from public, anon, authenticated;
revoke execute on function public.ensure_cycle_sample_partition(bigint) from public, anon, authenticated;
revoke execute on function public.refresh_cycle_step_stats(bigint)      from public, anon, authenticated;

grant execute on function public.jsonb_float8_array(jsonb)             to service_role;
grant execute on function public.import_cycle(jsonb)                   to service_role;
grant execute on function public.purge_synthetic()                     to service_role;
grant execute on function public.ensure_cycle_sample_partition(bigint) to service_role;
grant execute on function public.refresh_cycle_step_stats(bigint)      to service_role;

-- ---------------------------------------------------------------- stockage des fichiers bruts
-- Bucket privé : seule la clé secrète (fonction serveur de la plateforme) y écrit.

do $$
begin
  if exists (select 1 from pg_namespace where nspname = 'storage') then
    insert into storage.buckets (id, name, public, file_size_limit)
    values ('exports', 'exports', false, 52428800)
    on conflict (id) do nothing;
  end if;
end $$;

-- Résumé d'un cycle pour le tableau de bord de l'app web (app/index.html).
--
-- Une ligne par cycle, calculée à partir de cycle_step_stats (agrégats par étape,
-- déjà calculés à l'import) : le navigateur ne lit jamais les mesures brutes pour
-- les graphiques inter-cycles, seulement pour la courbe d'un cycle ouvert.
-- Les colonnes suivent les noms du parseur de la page (app/index.html, parse()).
-- security_invoker : mêmes règles que les tables (compte autorisé uniquement).

create view public.v_cycle_resume with (security_invoker = true) as
select c.id                                   as db_id,
       c.drilling_cycle_id                    as cycle_id,
       c.started_at,
       c.source_file,
       c.is_synthetic,
       c.sample_rate_hz,
       c.cycle_ok,
       c.cycle_time_s,
       c.distance_mm,
       c.head_global_counter,
       c.head_local_counter_1,
       c.head_local_counter_2,
       c.box_firmware_version                 as firmware,
       b.box_sn, b.box_name,
       m.motor_name,
       h.head_name, h.head_tag_uid            as head_uid, h.head_type,
       p.pset_nb, p.pset_version,
       st.nb_mesures,
       st.couple_max_a, st.couple_moy_a,
       st.poussee_max_a, st.poussee_moy_a,
       st.puissance_max_w, st.energie_kj,
       st.course_mm, st.gap_max_mm,
       r.stop_code_max,
       r.etapes
  from public.cycle c
  join public.control_box b on b.id = c.box_id
  left join public.motor   m on m.id = c.motor_id
  left join public.head    h on h.id = c.head_id
  left join public.program p on p.id = c.program_id
  left join lateral (
    select sum(s.n_samples)                                           as nb_mesures,
           max(s.torque_max_a)                                        as couple_max_a,
           sum(s.torque_avg_a * s.n_samples) / nullif(sum(s.n_samples), 0) as couple_moy_a,
           max(s.thrust_max_a)                                        as poussee_max_a,
           sum(s.thrust_avg_a * s.n_samples) / nullif(sum(s.n_samples), 0) as poussee_moy_a,
           max(s.torque_power_max_w)                                  as puissance_max_w,
           sum(s.energy_j) / 1000                                     as energie_kj,
           max(greatest(s.position_start_mm, s.position_end_mm))
             - min(least(s.position_start_mm, s.position_end_mm))     as course_mm,
           max(s.gap_max_mm)                                          as gap_max_mm
      from public.cycle_step_stats s
     where s.cycle_id = c.id
  ) st on true
  left join lateral (
    select max(sr.stop_code) as stop_code_max,
           jsonb_agg(jsonb_build_object(
             'n', sr.step_nb,
             'duree_s', sr.duration_s,
             'stop_code', sr.stop_code,
             'm1_max_a', sr.m1_max_amp,
             'm2_max_a', sr.m2_max_amp,
             'distance_m2', sr.distance_m2,
             'couple_moy_a', ss.torque_avg_a,
             'poussee_moy_a', ss.thrust_avg_a,
             'couple_max_a', ss.torque_max_a) order by sr.step_nb) as etapes
      from public.cycle_step_result sr
      left join public.cycle_step_stats ss on ss.cycle_id = sr.cycle_id and ss.step_nb = sr.step_nb
     where sr.cycle_id = c.id
  ) r on true;

revoke all on public.v_cycle_resume from anon, authenticated;
grant select on public.v_cycle_resume to authenticated;

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

commit;
