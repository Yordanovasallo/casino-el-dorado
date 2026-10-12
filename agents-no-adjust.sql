-- ============================================================
-- AGENTES: ya no pueden sumar ni quitar fichas
-- ============================================================
drop function if exists public.agent_adjust(text, text, int, int, bigint);
