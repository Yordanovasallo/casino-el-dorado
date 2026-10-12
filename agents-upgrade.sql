-- ============================================================
-- RED DE AGENTES / AFILIADOS (estilo GGPoker)
-- Un agente capta jugadores, gestiona su saldo y gana comisión
-- sobre la ganancia neta que esos jugadores le generan a la casa.
-- ============================================================

-- ---------- 1) Columnas de agente en users ----------
alter table public.users add column if not exists agent boolean not null default false;
alter table public.users add column if not exists agent_id text;            -- agente dueño del jugador
alter table public.users add column if not exists agent_code text;          -- código de referido
alter table public.users add column if not exists commission int not null default 10;   -- % de comisión
alter table public.users add column if not exists commission_paid bigint not null default 0;
create unique index if not exists users_agent_code_uidx on public.users (agent_code) where agent_code is not null;

-- ---------- 2) login / get_user: devuelven datos de agente ----------
create or replace function public.login(p_id text, p_pass text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare r users;
begin
  if p_id ~ '^[0-9]+$' then
    select * into r from users where num = p_id::bigint and pass = p_pass;
  end if;
  if r.id is null then
    select * into r from users where id = p_id and pass = p_pass;
  end if;
  if r.id is null then return null; end if;
  return jsonb_build_object('id', r.id, 'num', r.num, 'name', r.name,
                            'balance', r.balance, 'avatar', r.avatar, 'admin', r.admin,
                            'agent', r.agent, 'agent_code', r.agent_code,
                            'commission', r.commission, 'agent_id', r.agent_id);
end $$;

create or replace function public.get_user(p_id text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare r users;
begin
  if p_id ~ '^[0-9]+$' then
    select * into r from users where num = p_id::bigint;
  end if;
  if r.id is null then
    select * into r from users where id = p_id;
  end if;
  if r.id is null then return null; end if;
  return jsonb_build_object('id', r.id, 'num', r.num, 'name', r.name,
                            'balance', r.balance, 'avatar', r.avatar, 'admin', r.admin,
                            'agent', r.agent, 'agent_code', r.agent_code,
                            'commission', r.commission, 'agent_id', r.agent_id);
end $$;

-- ---------- 3) Aplicar código de referido ----------
create or replace function public.apply_referral(p_user_id text, p_code text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare u users; a users; c text;
begin
  select * into u from users where id = p_user_id for update;
  if not found then raise exception 'Sesión expirada.'; end if;
  if u.agent then raise exception 'Una cuenta de agente no puede tener referidor.'; end if;
  c := upper(trim(coalesce(p_code,'')));
  if c = '' then return jsonb_build_object('ok', false); end if;
  select * into a from users where agent_code = c and agent;
  if not found then raise exception 'Código de agente no válido.'; end if;
  if a.id = p_user_id then raise exception 'No puedes usar tu propio código.'; end if;
  update users set agent_id = a.id where id = p_user_id;
  return jsonb_build_object('ok', true, 'agent', a.name, 'agent_id', a.id);
end $$;

-- ============================================================
-- 4) RPC de ADMINISTRACIÓN de agentes
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
      'players', (select count(*) from users u where u.agent_id = a.id),
      'players_balance', coalesce((select sum(balance) from users u where u.agent_id = a.id), 0),
      'house_profit', coalesce((
        select sum(greatest(0, -coalesce(l.s,0)))
        from users u
        left join lateral (
          select sum(amount) s from ledger where uname = u.name
            and type not in ('Recarga','Retiro','Transferencia','Transferencia recibida')
        ) l on true
        where u.agent_id = a.id), 0)
    ) order by a.num)
    from users a where a.agent), '[]'::jsonb);
end $$;

create or replace function public.admin_agent_set(p_admin text, p_user_id text, p_is_agent boolean, p_commission int, p_code text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare u users; c text;
begin
  if not exists (select 1 from users where id = p_admin and admin) then
    raise exception 'Solo el administrador.'; end if;
  select * into u from users where id = p_user_id for update;
  if not found then raise exception 'Usuario no encontrado.'; end if;
  if u.admin then raise exception 'La cuenta de administración no puede ser agente.'; end if;
  if p_is_agent then
    c := nullif(upper(trim(coalesce(p_code,''))), '');
    if c is null then c := 'AG' || u.num; end if;
    if exists (select 1 from users where agent_code = c and id <> p_user_id) then
      raise exception 'Ese código ya está en uso.';
    end if;
    update users set agent = true, agent_code = c,
      commission = greatest(0, coalesce(p_commission, 10)), agent_id = null
      where id = p_user_id;
  else
    update users set agent = false, agent_code = null where id = p_user_id;
    update users set agent_id = null where agent_id = p_user_id;
  end if;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.admin_agent_assign(p_admin text, p_player text, p_agent text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare pl users;
begin
  if not exists (select 1 from users where id = p_admin and admin) then
    raise exception 'Solo el administrador.'; end if;
  select * into pl from users where id = p_player for update;
  if not found then raise exception 'Jugador no encontrado.'; end if;
  if pl.admin then raise exception 'No puedes asignar la cuenta de administración.'; end if;
  if pl.agent then raise exception 'No puedes asignar un agente como jugador.'; end if;
  if p_agent is not null and p_agent <> '' then
    if not exists (select 1 from users where id = p_agent and agent) then
      raise exception 'El agente no existe.'; end if;
    update users set agent_id = p_agent where id = p_player;
  else
    update users set agent_id = null where id = p_player;
  end if;
  return jsonb_build_object('ok', true);
end $$;

-- ============================================================
-- 5) RPC del AGENTE (gestiona solo a sus jugadores)
-- ============================================================
create or replace function public.agent_summary(p_agent text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare ag users; pl int; tot bigint; profit bigint; earned int; pend int;
begin
  select * into ag from users where id = p_agent and agent;
  if not found then return jsonb_build_object('is_agent', false); end if;
  select count(*), coalesce(sum(balance),0) into pl, tot from users where agent_id = p_agent;
  select coalesce(sum(greatest(0, -coalesce(l.s,0))),0) into profit
    from users u
    left join lateral (
      select sum(amount) s from ledger where uname = u.name
        and type not in ('Recarga','Retiro','Transferencia','Transferencia recibida')
    ) l on true
    where u.agent_id = p_agent;
  earned := (floor(profit * ag.commission / 100.0))::int;
  pend := greatest(0, earned - ag.commission_paid);
  return jsonb_build_object('is_agent', true, 'code', ag.agent_code, 'commission', ag.commission,
    'players', pl, 'managed_balance', tot, 'house_profit', profit,
    'earned', earned, 'paid', ag.commission_paid, 'pending', pend);
end $$;

create or replace function public.agent_players(p_agent text)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from users where id = p_agent and agent) then
    raise exception 'No eres agente.'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', u.id, 'num', u.num, 'name', u.name, 'avatar', u.avatar,
      'balance', u.balance, 'created', u.created,
      'net', coalesce((
        select sum(amount) from ledger where uname = u.name
          and type not in ('Recarga','Retiro','Transferencia','Transferencia recibida')), 0))
      order by u.created desc, u.num desc)
    from users u where u.agent_id = p_agent), '[]'::jsonb);
end $$;

create or replace function public.agent_player_stats(p_agent text, p_player text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  u users; bytype jsonb; last jsonb; won int := 0; lost int := 0; tot int := 0;
begin
  if not exists (select 1 from users where id = p_agent and agent) then
    raise exception 'No eres agente.'; end if;
  select * into u from users where id = p_player;
  if u.id is null then raise exception 'Ese jugador no existe.'; end if;
  if u.agent_id is distinct from p_agent then
    raise exception 'Ese jugador no es tuyo.'; end if;
  bytype := coalesce((
    select jsonb_agg(jsonb_build_object('type', t.type, 'count', t.n, 'sum', t.s) order by t.s desc)
    from (select type, count(*) n, coalesce(sum(amount),0) s from ledger where uname = u.name group by type) t
  ), '[]'::jsonb);
  select
    coalesce(sum(case when type not in ('Recarga','Retiro','Transferencia','Transferencia recibida') and amount > 0 then amount else 0 end),0),
    coalesce(sum(case when type not in ('Recarga','Retiro','Transferencia','Transferencia recibida') and amount < 0 then amount else 0 end),0),
    coalesce(sum(amount),0)
   into won, lost, tot
   from ledger where uname = u.name;
  last := coalesce((
    select jsonb_agg(jsonb_build_object('date', x.date, 'type', x.type, 'amount', x.amount, 'detail', x.detail, 'ts', x.ts) order by x.ts desc)
    from (select date, type, amount, detail, ts from ledger where uname = u.name order by ts desc limit 60) x
  ), '[]'::jsonb);
  return jsonb_build_object('id', u.id, 'num', u.num, 'name', u.name, 'balance', u.balance,
    'created', u.created, 'avatar', u.avatar, 'won', won, 'lost', lost, 'gameNet', won + lost,
    'net', tot, 'byType', bytype, 'last', last);
end $$;

create or replace function public.agent_adjust(p_agent text, p_player text, p_amount int, p_sign int, p_now bigint)
returns void language plpgsql security definer set search_path = public as $$
declare pl users; ag users;
begin
  select * into ag from users where id = p_agent and agent;
  if not found then raise exception 'No eres agente.'; end if;
  if p_amount is null or p_amount <= 0 then raise exception 'Cantidad no válida.'; end if;
  if p_sign not in (-1, 1) then raise exception 'Operación no válida.'; end if;
  select * into pl from users where id = p_player for update;
  if not found then raise exception 'Jugador no encontrado.'; end if;
  if pl.agent_id is distinct from p_agent then raise exception 'Ese jugador no es tuyo.'; end if;
  if pl.balance + p_sign * p_amount < 0 then raise exception 'El jugador no tiene suficientes fichas.'; end if;
  update users set balance = balance + p_sign * p_amount where id = p_player;
  insert into ledger (date, uname, type, amount, detail, ts)
  values (to_char(now(), 'DD/MM/YYYY HH24:MI:SS'), pl.name,
          case when p_sign > 0 then 'Recarga' else 'Retiro' end, p_sign * p_amount,
          'Ajuste del agente ' || ag.name, p_now);
end $$;

create or replace function public.agent_pay_commission(p_agent text, p_now bigint)
returns jsonb language plpgsql security definer set search_path = public as $$
declare ag users; profit bigint; earned int; pend int;
begin
  select * into ag from users where id = p_agent and agent for update;
  if not found then raise exception 'No eres agente.'; end if;
  select coalesce(sum(greatest(0, -coalesce(l.s,0))),0) into profit
    from users u
    left join lateral (
      select sum(amount) s from ledger where uname = u.name
        and type not in ('Recarga','Retiro','Transferencia','Transferencia recibida')
    ) l on true
    where u.agent_id = p_agent;
  earned := (floor(profit * ag.commission / 100.0))::int;
  pend := greatest(0, earned - ag.commission_paid);
  if pend > 0 then
    update users set balance = balance + pend, commission_paid = commission_paid + pend where id = p_agent;
    insert into ledger (date, uname, type, amount, detail, ts)
    values (to_char(now(), 'DD/MM/YYYY HH24:MI:SS'), ag.name, 'Comisión agente', pend,
            'Comisión por tus jugadores afiliados', p_now);
  end if;
  return jsonb_build_object('paid', pend);
end $$;

-- ============================================================
-- 6) Permisos
-- ============================================================
grant execute on function public.login(text, text) to anon, authenticated;
grant execute on function public.get_user(text) to anon, authenticated;
grant execute on function public.apply_referral(text, text) to anon, authenticated;
grant execute on function public.admin_agent_list(text) to anon, authenticated;
grant execute on function public.admin_agent_set(text, text, boolean, int, text) to anon, authenticated;
grant execute on function public.admin_agent_assign(text, text, text) to anon, authenticated;
grant execute on function public.agent_summary(text) to anon, authenticated;
grant execute on function public.agent_players(text) to anon, authenticated;
grant execute on function public.agent_player_stats(text, text) to anon, authenticated;
grant execute on function public.agent_adjust(text, text, int, int, bigint) to anon, authenticated;
grant execute on function public.agent_pay_commission(text, bigint) to anon, authenticated;
