-- ============================================================
-- AGENTES: congelar la comision de cada dia tal como termino
-- ============================================================
alter table public.agent_commission add column if not exists rate int not null default 0;

-- Solo se recalcula el dia en curso; los dias pasados quedan intactos.
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
      insert into agent_commission (agent_id, player_id, day, profit, commission, rate, updated)
      values (r.aid, r.pid, r.d, r.profit, floor(r.profit * r.rate / 100.0)::bigint, r.rate, nowms)
      on conflict (agent_id, player_id, day)
      do update set profit = excluded.profit, commission = excluded.commission, rate = excluded.rate, updated = excluded.updated
      where agent_commission.day = current_date
         or (agent_commission.day = current_date - 1 and extract(hour from now()) < 1);
    end if;
  end loop;
end $$;

revoke all on function public.agent_commission_refresh(text) from public, anon, authenticated;
