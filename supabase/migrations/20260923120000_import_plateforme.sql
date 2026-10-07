-- Intégration des fichiers d'export par la plateforme web et le script CLI.
--
--   * import_cycle(p jsonb) : point d'entrée unique. Reçoit un fichier déjà découpé
--     (voir plateforme/lib/parser.ts et ingestion/charger_cycles.py, même contrat) et
--     écrit dimensions, programme, cycle, étapes, mesures et agrégats dans une seule
--     transaction. Appelée en HTTPS via l'API (clé secrète) : aucun accès direct à la
--     base n'est nécessaire.
--   * import_file : journal de chaque dépôt (importé, doublon, erreur), lisible sur
--     la plateforme.
--   * cycle.is_synthetic : les données générées par synthetique/generer.py sont
--     marquées et supprimables d'un coup avec purge_synthetic().
--   * bucket de stockage "exports" : copie compressée de chaque fichier déposé,
--     pour pouvoir réimporter si le découpage évolue.

-- ---------------------------------------------------------------- données synthétiques

alter table public.cycle add column is_synthetic boolean not null default false;
create index cycle_synthetic_idx on public.cycle (is_synthetic) where is_synthetic;

create or replace view public.v_cycle with (security_invoker = true) as
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

create or replace view public.v_cycle_step with (security_invoker = true) as
select c.id                  as cycle_id,
       c.started_at,
       c.box_id, c.head_id, c.program_id,
       c.head_global_counter,
       r.step_nb,
       ps.rpm                as set_rpm,
       ps.feed_mm_s          as set_feed_mm_s,
       ps.feed_mm_tr         as set_feed_mm_tr,
       ps.stroke_mm          as set_stroke_mm,
       ps.torque_max_a       as set_torque_max_a,
       ps.thrust_max_a       as set_thrust_max_a,
       ps.torque_min_a       as set_torque_min_a,
       ps.gap_mm             as set_gap_mm,
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
create policy lecture_import_file on public.import_file for select to authenticated using (true);

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

-- La partition est créée par le propriétaire de la table, quel que soit l'appelant.
alter function public.ensure_cycle_sample_partition(bigint) security definer;

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
