-- ============================================================
-- AGENTES: lista de jugadores con su comision del dia de hoy
-- ============================================================
create or replace function public.agent_players(p_agent text)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from users where id = p_agent and agent) then
    raise exception 'No eres agente.'; end if;
  perform public.agent_commission_refresh(p_agent);
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', u.id, 'num', u.num, 'name', u.name, 'avatar', u.avatar,
      'balance', u.balance, 'created', u.created,
      'today', coalesce((select ac.commission from agent_commission ac
                         where ac.agent_id = p_agent and ac.player_id = u.id and ac.day = current_date), 0),
      'net', coalesce((
        select sum(amount) from ledger where uname = u.name
          and type not in ('Recarga','Retiro','Transferencia','Transferencia recibida')), 0))
      order by u.created desc, u.num desc)
    from users u where u.agent_id = p_agent), '[]'::jsonb);
end $$;

grant execute on function public.agent_players(text) to anon, authenticated;
