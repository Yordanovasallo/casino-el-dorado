-- ============================================================
-- ADMIN: ganancia total por dia, incluyendo el pago de agentes
-- ============================================================
create or replace function public.admin_daily_profit(p_admin text)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from users where id = p_admin and admin) then
    raise exception 'Solo el administrador.'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'day', d.day, 'profit', d.profit,
      'commission', coalesce(c.commission, 0),
      'net', d.profit - coalesce(c.commission, 0)
    ) order by d.day desc)
    from (
      select (to_timestamp(ts/1000.0))::date as day, (-sum(amount))::bigint as profit
      from ledger
      where ts is not null
        and type not in ('Recarga','Retiro','Transferencia','Transferencia recibida','Comisión agente')
      group by 1
    ) d
    left join (
      select day, sum(commission)::bigint as commission
      from agent_commission group by day
    ) c on c.day = d.day
  ), '[]'::jsonb);
end $$;

grant execute on function public.admin_daily_profit(text) to anon, authenticated;
