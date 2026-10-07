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
