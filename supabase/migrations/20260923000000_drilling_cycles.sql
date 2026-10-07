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
  unique (box_id, drilling_cycle_id)
);

create index cycle_started_at_idx on public.cycle (started_at);
create index cycle_head_idx       on public.cycle (head_id, head_global_counter);
create index cycle_program_idx    on public.cycle (program_id);
create index cycle_motor_idx      on public.cycle (motor_id);

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
       c.source_file
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
       st.torque_power_avg_w, st.energy_j
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
-- connectés. Aucune politique d'écriture : l'API web (clé publique) ne peut rien
-- modifier. Les vues sont en security_invoker, elles héritent de ces règles.
-- Pour ouvrir la lecture sans connexion, remplacer "to authenticated" par
-- "to anon, authenticated" (les données deviennent alors lisibles par quiconque
-- connaît l'URL du projet).

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
      'create policy %I on public.%I for select to authenticated using (true)',
      'lecture_' || t, t);
  end loop;
end $$;

revoke all on public.v_cycle, public.v_cycle_step, public.v_cycle_sample from anon, authenticated;
grant select on public.v_cycle, public.v_cycle_step, public.v_cycle_sample to authenticated;

-- fonctions d'import : réservées au script de chargement
revoke execute on function public.refresh_cycle_step_stats(bigint)       from public, anon, authenticated;
revoke execute on function public.ensure_cycle_sample_partition(bigint)  from public, anon, authenticated;
