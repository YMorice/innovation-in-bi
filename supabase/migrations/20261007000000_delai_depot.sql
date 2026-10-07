-- Délai du dépôt depuis la page (app/index.html).
--
-- deposer_cycle est appelée avec la session de l'utilisateur : rôle authenticated, dont les
-- requêtes sont coupées au bout de 8 s. Un long export (plusieurs dizaines de milliers de
-- mesures) dépasse ce délai : « canceling statement due to statement timeout », et rien
-- n'est noté au journal.
--
-- PostgREST applique le statement_timeout d'une fonction appelée en RPC : 60 s pour
-- celle-ci seulement, les autres requêtes de la page gardent 8 s.
-- Mesuré sur le projet synthétique : 93 590 mesures intégrées en 11 s.

alter function public.deposer_cycle(jsonb, text, text, int, text, text) set statement_timeout = '60s';
