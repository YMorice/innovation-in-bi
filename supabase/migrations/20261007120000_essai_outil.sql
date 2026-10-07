-- Essai d'outil coupant, lu dans le nom du dossier des exports.
--
-- Les exports d'un même essai sont rangés dans un dossier nommé comme
-- « DT00012 - acme foret Ø8.5 » : code de l'essai, fournisseur de l'outil,
-- désignation, diamètre. Jusqu'ici la page et le script ne gardaient que le nom du
-- fichier, et le dossier était perdu. Désormais :
--   * cycle.source_path garde le chemin déposé, dossiers compris (null pour un
--     fichier déposé seul) ;
--   * essai : une ligne par code DT, créée au premier cycle de l'essai. Les valeurs
--     lues dans le nom du dossier peuvent être corrigées à la main dans l'éditeur SQL :
--     un import suivant ne les écrase pas ;
--   * un fichier déjà en base, redéposé avec son dossier, est rattaché à son essai
--     (« fichier déjà importé, dossier rattaché »). C'est ainsi que les cycles importés
--     avant cette migration récupèrent leur fournisseur.
--
-- La page et le script ajoutent "source_path" au document envoyé à import_cycle.
-- Avant cette migration, la clé est ignorée ; après, un ancien envoi sans elle
-- s'importe comme avant, sans essai : l'ordre de déploiement est libre.

create table public.essai (
  id           bigint generated always as identity primary key,
  code         text not null unique,   -- « DT00012 »
  libelle      text not null,          -- nom complet du dossier
  fournisseur  text,                   -- premier mot, en majuscules sans accent : « ACME »
  designation  text,                   -- le reste, hors diamètre : « foret »
  diametre_mm  numeric,                -- « Ø8.5 », « ø 6,8 mm » -> 8.5, 6.8
  extra        jsonb not null default '{}',
  created_at   timestamptz not null default now()
);

alter table public.cycle
  add column source_path text,
  add column essai_id    bigint references public.essai (id);

create index cycle_essai_idx on public.cycle (essai_id);

alter table public.essai enable row level security;
revoke all on public.essai from anon, authenticated;
grant select on public.essai to authenticated;
create policy lecture_essai on public.essai for select to authenticated using ((select public.est_autorise()));

-- Chemin d'un export -> essai. Le dossier retenu est le plus proche du fichier dont le
-- nom commence par « DT » suivi de chiffres. Sans un tel dossier, tout est null.
create or replace function public.essai_lire_chemin(
  p_path          text,
  out code        text,
  out libelle     text,
  out fournisseur text,
  out designation text,
  out diametre_mm numeric)
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_dossiers text[];
  v_m        text[];
  v_reste    text;
  v_mot      text;
begin
  v_dossiers := string_to_array(normalize(coalesce(p_path, ''), nfc), '/');
  -- le dernier élément est le fichier lui-même
  for i in reverse coalesce(array_length(v_dossiers, 1), 0) - 1 .. 1 loop
    v_m := regexp_match(v_dossiers[i], '^\s*DT\s*(\d+)\s*[-–—_:]*\s*(.*)$', 'i');
    if v_m is not null then
      libelle := btrim(v_dossiers[i]);
      exit;
    end if;
  end loop;
  if v_m is null then
    return;
  end if;
  code := 'DT' || v_m[1];
  diametre_mm := replace((regexp_match(v_m[2], '[ØøΦφ⌀]\s*(\d+(?:[.,]\d+)?)'))[1], ',', '.')::numeric;
  v_reste := btrim(regexp_replace(regexp_replace(v_m[2], '[ØøΦφ⌀]\s*\d+(?:[.,]\d+)?\s*(mm\M)?', ' ', 'gi'), '\s+', ' ', 'g'));
  v_mot := split_part(v_reste, ' ', 1);
  -- « müller » et « Muller » doivent tomber dans le même groupe
  fournisseur := nullif(upper(translate(v_mot,
    'àâäáãéèêëíìîïóòôöõúùûüçñÀÂÄÁÃÉÈÊËÍÌÎÏÓÒÔÖÕÚÙÛÜÇÑ',
    'aaaaaeeeeiiiiooooouuuucnAAAAAEEEEIIIIOOOOOUUUUCN')), '');
  designation := nullif(btrim(substr(v_reste, length(v_mot) + 1)), '');
end $$;

-- Essai du chemin, créé s'il n'existe pas encore. Un essai déjà connu garde ses
-- valeurs (éventuellement corrigées à la main).
create or replace function public.essai_depuis_chemin(p_path text)
returns bigint
language plpgsql
set search_path = ''
as $$
declare
  e    record;
  v_id bigint;
begin
  select * into e from public.essai_lire_chemin(p_path);
  if e.code is null then
    return null;
  end if;
  insert into public.essai (code, libelle, fournisseur, designation, diametre_mm)
  values (e.code, e.libelle, e.fournisseur, e.designation, e.diametre_mm)
  on conflict (code) do nothing
  returning id into v_id;
  if v_id is null then
    select id into v_id from public.essai where code = e.code;
  end if;
  return v_id;
end $$;

-- Cycle déjà en base, redéposé : prend le chemin du nouveau dépôt s'il n'a pas encore
-- d'essai. Renvoie vrai si le cycle vient d'être rattaché à un essai.
create or replace function public.rattacher_dossier(p_cycle bigint, p_path text)
returns boolean
language plpgsql
set search_path = ''
as $$
declare
  v_essai bigint;
begin
  if p_path is null or p_cycle is null then
    return false;
  end if;
  update public.cycle
     set source_path = normalize(p_path, nfc),
         essai_id    = public.essai_depuis_chemin(p_path)
   where id = p_cycle and essai_id is null
  returning essai_id into v_essai;
  return v_essai is not null;
end $$;

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
  v_rattache  boolean;
  s           jsonb := p->'samples';
begin
  select id into v_existing from public.cycle where source_sha256 = p->>'source_sha256';
  if v_existing is not null then
    v_rattache := public.rattacher_dossier(v_existing, p->>'source_path');
    return jsonb_build_object('status', 'doublon', 'cycle_id', v_existing, 'rattache', v_rattache,
                              'message', 'fichier déjà importé'
                                         || case when v_rattache then ', dossier rattaché' else '' end);
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
          distance_mm, cycle_ok, source_file, source_sha256, source_path, essai_id,
          is_synthetic, extra)
  select r.drilling_cycle_id, r.started_at, r.file_version, r.sample_rate_hz, v_box, v_motor,
         v_head, v_program, r.box_release, r.box_firmware_version, r.box_maintenance_date,
         r.box_operation_time, r.pset_default_selection, r.motor_operation_time,
         r.head_global_counter, r.head_local_counter_1, r.head_local_counter_2,
         r.cycle_time_s, r.distance_mm, r.cycle_ok, r.source_file, r.source_sha256,
         normalize(r.source_path, nfc), public.essai_depuis_chemin(r.source_path),
         coalesce(r.is_synthetic, false), coalesce(r.extra, '{}')
    from jsonb_populate_record(null::public.cycle, p) r
  on conflict (box_id, drilling_cycle_id) do nothing
  returning id into v_cycle;

  if v_cycle is null then
    select id into v_existing from public.cycle
     where box_id = v_box and drilling_cycle_id = (p->>'drilling_cycle_id')::bigint;
    v_rattache := public.rattacher_dossier(v_existing, p->>'source_path');
    return jsonb_build_object('status', 'doublon', 'cycle_id', v_existing, 'rattache', v_rattache,
                              'message', 'cycle déjà connu (même boîtier et Drilling Cycle ID)'
                                         || case when v_rattache then ', dossier rattaché' else '' end);
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
  delete from public.essai e where not exists (select 1 from public.cycle c where c.essai_id = e.id);
  return jsonb_build_object('cycles_supprimes', v_cycles);
end $$;

revoke execute on function public.essai_lire_chemin(text)          from public, anon, authenticated;
revoke execute on function public.essai_depuis_chemin(text)        from public, anon, authenticated;
revoke execute on function public.rattacher_dossier(bigint, text)  from public, anon, authenticated;
grant execute on function public.essai_lire_chemin(text)           to service_role;
grant execute on function public.essai_depuis_chemin(text)         to service_role;
grant execute on function public.rattacher_dossier(bigint, text)   to service_role;

-- Vues : colonnes de l'essai ajoutées à la fin (create or replace view ne peut
-- qu'ajouter des colonnes après les existantes).

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
       c.is_synthetic,
       c.source_path,
       e.code                as essai_code,
       e.libelle             as essai_libelle,
       e.fournisseur,
       e.designation,
       e.diametre_mm
  from public.cycle c
  join public.control_box b on b.id = c.box_id
  left join public.motor   m on m.id = c.motor_id
  left join public.head    h on h.id = c.head_id
  left join public.program p on p.id = c.program_id
  left join public.essai   e on e.id = c.essai_id;

create or replace view public.v_cycle_resume with (security_invoker = true) as
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
       r.etapes,
       c.source_path,
       e.code                                 as essai_code,
       e.libelle                              as essai_libelle,
       e.fournisseur,
       e.designation,
       e.diametre_mm
  from public.cycle c
  join public.control_box b on b.id = c.box_id
  left join public.motor   m on m.id = c.motor_id
  left join public.head    h on h.id = c.head_id
  left join public.program p on p.id = c.program_id
  left join public.essai   e on e.id = c.essai_id
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
