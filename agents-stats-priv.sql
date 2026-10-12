-- ============================================================
-- AGENTES: la vista del agente no expone ganancias de la casa
-- ============================================================
create or replace function public.agent_summary(p_agent text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare ag users; pl int; tot bigint; earned bigint; pend bigint;
begin
  select * into ag from users where id = p_agent and agent;
  if not found then return jsonb_build_object('is_agent', false); end if;
  perform public.agent_commission_refresh(p_agent);
  select count(*), coalesce(sum(balance),0) into pl, tot from users where agent_id = p_agent;
  select coalesce(sum(commission),0) into earned from agent_commission where agent_id = p_agent;
  pend := greatest(0, earned - ag.commission_paid);
  return jsonb_build_object('is_agent', true, 'code', ag.agent_code, 'commission', ag.commission,
    'players', pl, 'managed_balance', tot,
    'earned', earned, 'paid', ag.commission_paid, 'pending', pend);
end $$;

-- Reporte del agente: solo su comision, por dia y por jugador (de ese dia).
create or replace function public.agent_commission_report(p_agent text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare ag users; byday jsonb; bypd jsonb; tot_c bigint;
begin
  select * into ag from users where id = p_agent and agent;
  if not found then raise exception 'No eres agente.'; end if;
  perform public.agent_commission_refresh(p_agent);
  select coalesce(sum(commission),0) into tot_c from agent_commission where agent_id = p_agent;
  select coalesce(jsonb_agg(jsonb_build_object('day', d.day, 'players', d.players, 'commission', d.commission) order by d.day desc), '[]'::jsonb)
    into byday from (
      select day, count(distinct player_id)::int as players, sum(commission)::bigint as commission
      from agent_commission where agent_id = p_agent group by day
    ) d;
  select coalesce(jsonb_agg(jsonb_build_object('day', x.day, 'id', p.id, 'num', p.num, 'name', p.name, 'commission', x.commission) order by x.day desc, x.commission desc, p.num), '[]'::jsonb)
    into bypd from (
      select day, player_id, commission from agent_commission where agent_id = p_agent
    ) x join users p on p.id = x.player_id;
  return jsonb_build_object('rate', ag.commission, 'total_commission', tot_c,
    'by_day', byday, 'by_player_day', bypd);
end $$;

grant execute on function public.agent_summary(text) to anon, authenticated;
grant execute on function public.agent_commission_report(text) to anon, authenticated;
