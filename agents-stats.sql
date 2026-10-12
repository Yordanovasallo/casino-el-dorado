-- ============================================================
-- AGENTES: registro permanente de comisiones por dia y jugador
-- ============================================================
create table if not exists public.agent_commission (
  agent_id text not null,
  player_id text not null,
  day date not null,
  profit bigint not null default 0,
  commission bigint not null default 0,
  updated bigint not null default 0,
  primary key (agent_id, player_id, day)
);

create index if not exists agent_commission_agent_idx on public.agent_commission (agent_id);

alter table public.agent_commission enable row level security;

-- Recalcula (upsert, nunca borra) la comision diaria por jugador.
create or replace function public.agent_commission_refresh(p_agent text default null)
returns void language plpgsql security definer set search_path = public as $$
declare r record; nowms bigint := (extract(epoch from now())*1000)::bigint;
begin
  for r in
    with g as (
      select u.id as pid, u.agent_id as aid,
             (to_timestamp(l.ts/1000.0))::date as d,
             sum(l.amount) as net
      from ledger l
      join users u on u.name = l.uname
      where u.agent_id is not null
        and l.ts is not null
        and l.type not in ('Recarga','Retiro','Transferencia','Transferencia recibida')
      group by u.id, u.agent_id, (to_timestamp(l.ts/1000.0))::date
    )
    select g.aid, g.pid, g.d, ag.commission as rate, greatest(0, -g.net) as profit
    from g join users ag on ag.id = g.aid and ag.agent
    where (p_agent is null or g.aid = p_agent)
  loop
    if r.profit > 0 then
      insert into agent_commission (agent_id, player_id, day, profit, commission, updated)
      values (r.aid, r.pid, r.d, r.profit, floor(r.profit * r.rate / 100.0)::bigint, nowms)
      on conflict (agent_id, player_id, day)
      do update set profit = excluded.profit, commission = excluded.commission, updated = excluded.updated;
    end if;
  end loop;
end $$;

-- Reporte para el agente: totales + por dias + por jugador.
create or replace function public.agent_commission_report(p_agent text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare ag users; byday jsonb; byplayer jsonb; tot_c bigint; tot_p bigint;
begin
  select * into ag from users where id = p_agent and agent;
  if not found then raise exception 'No eres agente.'; end if;
  perform public.agent_commission_refresh(p_agent);
  select coalesce(sum(commission),0), coalesce(sum(profit),0)
    into tot_c, tot_p from agent_commission where agent_id = p_agent;
  select coalesce(jsonb_agg(jsonb_build_object('day', d.day, 'players', d.players, 'profit', d.profit, 'commission', d.commission) order by d.day desc), '[]'::jsonb)
    into byday from (
      select day, count(distinct player_id)::int as players,
             sum(profit)::bigint as profit, sum(commission)::bigint as commission
      from agent_commission where agent_id = p_agent group by day
    ) d;
  select coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'num', p.num, 'name', p.name, 'profit', x.profit, 'commission', x.commission) order by x.commission desc, p.num), '[]'::jsonb)
    into byplayer from (
      select player_id, sum(profit)::bigint as profit, sum(commission)::bigint as commission
      from agent_commission where agent_id = p_agent group by player_id
    ) x join users p on p.id = x.player_id;
  return jsonb_build_object('rate', ag.commission, 'total_profit', tot_p, 'total_commission', tot_c,
    'by_day', byday, 'by_player', byplayer);
end $$;

-- agent_summary pasa a leer del registro permanente.
create or replace function public.agent_summary(p_agent text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare ag users; pl int; tot bigint; gprofit bigint; earned bigint; pend bigint;
begin
  select * into ag from users where id = p_agent and agent;
  if not found then return jsonb_build_object('is_agent', false); end if;
  perform public.agent_commission_refresh(p_agent);
  select count(*), coalesce(sum(balance),0) into pl, tot from users where agent_id = p_agent;
  select coalesce(sum(ac.profit),0), coalesce(sum(ac.commission),0) into gprofit, earned
    from agent_commission ac where ac.agent_id = p_agent;
  pend := greatest(0, earned - ag.commission_paid);
  return jsonb_build_object('is_agent', true, 'code', ag.agent_code, 'commission', ag.commission,
    'players', pl, 'managed_balance', tot, 'house_profit', gprofit,
    'earned', earned, 'paid', ag.commission_paid, 'pending', pend);
end $$;

-- Cobrar comision tambien desde el registro permanente.
create or replace function public.agent_pay_commission(p_agent text, p_now bigint)
returns jsonb language plpgsql security definer set search_path = public as $$
declare ag users; earned bigint; pend bigint;
begin
  select * into ag from users where id = p_agent and agent for update;
  if not found then raise exception 'No eres agente.'; end if;
  perform public.agent_commission_refresh(p_agent);
  select coalesce(sum(commission),0) into earned from agent_commission where agent_id = p_agent;
  pend := greatest(0, earned - ag.commission_paid);
  if pend > 0 then
    update users set balance = balance + pend, commission_paid = commission_paid + pend where id = p_agent;
    insert into ledger (date, uname, type, amount, detail, ts)
    values (to_char(now(), 'DD/MM/YYYY HH24:MI:SS'), ag.name, 'Comisión agente', pend,
            'Comisión por tus jugadores afiliados', p_now);
  end if;
  return jsonb_build_object('paid', pend);
end $$;

-- Admin: ganancia acumulada leida del registro (sin escanear el ledger en cada poll).
create or replace function public.admin_agent_list(p_admin text)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from users where id = p_admin and admin) then
    raise exception 'Solo el administrador.'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', a.id, 'num', a.num, 'name', a.name, 'code', a.agent_code,
      'commission', a.commission, 'commission_paid', a.commission_paid,
      'players', (select count(*) from users u where u.agent_id = a.id),
      'players_balance', coalesce((select sum(balance) from users u where u.agent_id = a.id), 0),
      'house_profit', coalesce((select sum(profit) from agent_commission where agent_id = a.id), 0)
    ) order by a.num)
    from users a where a.agent), '[]'::jsonb);
end $$;

-- ============================================================
-- Permisos
-- ============================================================
grant execute on function public.agent_commission_report(text) to anon, authenticated;
grant execute on function public.agent_summary(text) to anon, authenticated;
grant execute on function public.agent_pay_commission(text, bigint) to anon, authenticated;
grant execute on function public.admin_agent_list(text) to anon, authenticated;
revoke all on function public.agent_commission_refresh(text) from public, anon, authenticated;

-- ============================================================
-- Cron: mantiene el registro al dia (upsert; nunca borra)
-- ============================================================
do $$ begin perform cron.unschedule('agent_commission'); exception when others then null; end $$;
select cron.schedule('agent_commission', '*/10 * * * *', 'select public.agent_commission_refresh();');
