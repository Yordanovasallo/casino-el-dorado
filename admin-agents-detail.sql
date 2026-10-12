-- ============================================================
-- ADMIN: lista de agentes incluyendo los usuarios que dirigen
-- ============================================================
create or replace function public.admin_agent_list(p_admin text)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from users where id = p_admin and admin) then
    raise exception 'Solo el administrador.'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', a.id, 'num', a.num, 'name', a.name, 'code', a.agent_code,
      'commission', a.commission, 'commission_paid', a.commission_paid,
      'players_count', (select count(*) from users u where u.agent_id = a.id),
      'players_balance', coalesce((select sum(balance) from users u where u.agent_id = a.id), 0),
      'house_profit', coalesce((select sum(profit) from agent_commission where agent_id = a.id), 0),
      'players', coalesce((
        select jsonb_agg(jsonb_build_object('id', u.id, 'num', u.num, 'name', u.name, 'balance', u.balance) order by u.created desc)
        from users u where u.agent_id = a.id), '[]'::jsonb)
    ) order by a.num)
    from users a where a.agent), '[]'::jsonb);
end $$;

grant execute on function public.admin_agent_list(text) to anon, authenticated;