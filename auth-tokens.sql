-- ============================================================
-- Autenticación real por token de sesión
-- El cliente ya NO envía su propio id para identificarse: envía
-- un token opaco emitido por login()/register_user().
-- ============================================================

create extension if not exists pgcrypto;

-- Los nombres de parámetros cambian (p_id/p_admin/p_agent/p_user_id -> p_token);
-- CREATE OR REPLACE no permite renombrar, así que se eliminan primero.
drop function if exists public.login(text, text);
drop function if exists public.register_user(text, text, text, integer, boolean, bigint);
drop function if exists public.get_user(text);
drop function if exists public.change_password(text, text);
drop function if exists public.set_avatar(text, text);
drop function if exists public.apply_referral(text, text);
drop function if exists public.send_fichas(text, text, integer, bigint);
drop function if exists public.admin_adjust(text, text, integer, integer, bigint);
drop function if exists public.admin_delete_user(text, text);
drop function if exists public.admin_user_stats(text, text);
drop function if exists public.admin_users_list(text);
drop function if exists public.admin_agent_list(text);
drop function if exists public.admin_agent_set(text, text, boolean, integer, text);
drop function if exists public.admin_agent_assign(text, text, text);
drop function if exists public.admin_daily_profit(text);
drop function if exists public.agent_summary(text);
drop function if exists public.agent_players(text);
drop function if exists public.agent_player_stats(text, text);
drop function if exists public.agent_pay_commission(text, bigint);
drop function if exists public.agent_commission_report(text);
drop function if exists public.bets_list(text);
drop function if exists public.bets_place(text, text, text, integer, bigint);
drop function if exists public.bets_settle(text, text, text, bigint);
drop function if exists public.bets_void(text, text, bigint);
drop function if exists public.bets_admin_setup(text, text, jsonb);
drop function if exists public.join_round(text, text, integer, text, bigint);
drop function if exists public.scratch_buy(text, integer, bigint);
drop function if exists public.bets_admin_refresh(text);
drop function if exists public.bets_admin_settle(text);

create table if not exists public.sessions (
  token   text primary key,
  user_id text not null references public.users(id) on delete cascade,
  created bigint not null default 0,
  expires bigint not null default 0
);

create index if not exists sessions_user_uidx on public.sessions(user_id);

alter table public.sessions enable row level security;
-- sin políticas: nadie accede por PostgREST, solo las funciones definer

-- ---------- helpers internos ----------

create or replace function public._sess_user(p_token text)
returns public.users
language sql
security definer
set search_path to 'public'
as $$
  select u.*
  from public.sessions s
  join public.users u on u.id = s.user_id
  where s.token = p_token
    and s.expires > (extract(epoch from now()) * 1000)::bigint
  limit 1
$$;

create or replace function public._new_session(p_user_id text)
returns text
language plpgsql
security definer
set search_path to 'public'
as $$
declare t text; now_ms bigint;
begin
  now_ms := (extract(epoch from now()) * 1000)::bigint;
  delete from public.sessions where user_id = p_user_id;
  t := encode(extensions.gen_random_bytes(24), 'hex');
  insert into public.sessions(token, user_id, created, expires)
  values (t, p_user_id, now_ms, now_ms + 2592000000);
  return t;
end $$;

revoke all on function public._sess_user(text) from public, anon, authenticated;
revoke all on function public._new_session(text) from public, anon, authenticated;

-- ---------- autenticación ----------

create or replace function public.login(p_id text, p_pass text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare r users; t text;
begin
  if p_id ~ '^[0-9]+$' then
    select * into r from users where num = p_id::bigint and pass = p_pass;
  end if;
  if r.id is null then
    select * into r from users where id = p_id and pass = p_pass;
  end if;
  if r.id is null then return null; end if;
  t := public._new_session(r.id);
  return jsonb_build_object('id', r.id, 'num', r.num, 'name', r.name,
                            'balance', r.balance, 'avatar', r.avatar, 'admin', r.admin,
                            'agent', r.agent, 'agent_code', r.agent_code,
                            'commission', r.commission, 'agent_id', r.agent_id,
                            'token', t);
end $$;

drop function if exists public.register_user(text, text, text, integer, boolean, bigint);

create or replace function public.register_user(p_id text, p_name text, p_pass text, p_balance integer, p_admin boolean, p_created bigint)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare is_admin boolean; t text;
begin
  if exists(select 1 from users where id = p_id) then
    raise exception 'Ese usuario ya existe.';
  end if;
  is_admin := (p_id = 'admin') and not exists(select 1 from users where admin);
  insert into users (id, name, pass, balance, avatar, admin, created)
  values (p_id, p_name, p_pass, 0, '', coalesce(is_admin, false), p_created);
  t := public._new_session(p_id);
  return jsonb_build_object('id', p_id, 'admin', coalesce(is_admin, false), 'token', t);
end $$;

create or replace function public.get_user(p_token text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare r users;
begin
  r := public._sess_user(p_token);
  if r.id is null then return null; end if;
  return jsonb_build_object('id', r.id, 'num', r.num, 'name', r.name,
                            'balance', r.balance, 'avatar', r.avatar, 'admin', r.admin,
                            'agent', r.agent, 'agent_code', r.agent_code,
                            'commission', r.commission, 'agent_id', r.agent_id);
end $$;

create or replace function public.change_password(p_token text, p_pass text)
returns void
language plpgsql
security definer
set search_path to 'public'
as $$
declare me users;
begin
  me := public._sess_user(p_token);
  if me.id is null then raise exception 'Sesión expirada.'; end if;
  update users set pass = p_pass where id = me.id;
end $$;

create or replace function public.set_avatar(p_token text, p_avatar text)
returns void
language plpgsql
security definer
set search_path to 'public'
as $$
declare me users;
begin
  me := public._sess_user(p_token);
  if me.id is null then raise exception 'Sesión expirada.'; end if;
  update users set avatar = p_avatar where id = me.id;
end $$;

create or replace function public.apply_referral(p_token text, p_code text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare u users; a users; c text;
begin
  u := public._sess_user(p_token);
  if u.id is null then raise exception 'Sesión expirada.'; end if;
  if u.agent then raise exception 'Una cuenta de agente no puede tener referidor.'; end if;
  c := upper(trim(coalesce(p_code, '')));
  if c = '' then return jsonb_build_object('ok', false); end if;
  select * into a from users where agent_code = c and agent;
  if not found then raise exception 'Código de agente no válido.'; end if;
  if a.id = u.id then raise exception 'No puedes usar tu propio código.'; end if;
  update users set agent_id = a.id where id = u.id;
  return jsonb_build_object('ok', true, 'agent', a.name, 'agent_id', a.id);
end $$;

create or replace function public.send_fichas(p_token text, p_to text, p_amount integer, p_now bigint)
returns void
language plpgsql
security definer
set search_path to 'public'
as $$
declare me users; to_u users; date_txt text;
begin
  me := public._sess_user(p_token);
  if me.id is null then raise exception 'Sesión expirada. Cierra y vuelve a entrar.'; end if;
  select * into me from users where id = me.id for update;
  if p_to !~ '^[0-9]+$' then
    raise exception 'El destinatario debe ser el número de ID (solo números).';
  end if;
  select * into to_u from users where num = p_to::bigint for update;
  if not found then raise exception 'No existe ningún usuario con ese número de ID.'; end if;
  if to_u.id = me.id then raise exception 'No puedes enviarte fichas a ti mismo.'; end if;
  if me.balance < p_amount then raise exception 'Saldo insuficiente.'; end if;
  update users set balance = balance - p_amount where id = me.id;
  update users set balance = balance + p_amount where id = to_u.id;
  date_txt := to_char(now(), 'DD/MM/YYYY HH24:MI:SS');
  insert into ledger (date, uname, type, amount, detail, ts)
  values (date_txt, me.name, 'Transferencia', p_amount,
          'Envío a ' || to_u.name || ' (#' || to_u.num || ')', p_now);
  insert into ledger (date, uname, type, amount, detail, ts)
  values (date_txt, to_u.name, 'Transferencia recibida', p_amount,
          'Recibido de ' || me.name || ' (#' || me.num || ')', p_now);
end $$;

-- ---------- administración ----------

create or replace function public.admin_adjust(p_token text, p_to text, p_amount integer, p_sign integer, p_now bigint)
returns void
language plpgsql
security definer
set search_path to 'public'
as $$
declare a users; u users; new_bal int; date_txt text;
begin
  a := public._sess_user(p_token);
  if a.id is null or not a.admin then raise exception 'Solo el administrador puede ajustar fichas.'; end if;
  select * into u from users where id = p_to for update;
  if not found then raise exception 'Usuario no encontrado.'; end if;
  new_bal := u.balance + (p_sign * p_amount);
  if new_bal < 0 then raise exception 'El usuario no tiene suficientes fichas.'; end if;
  update users set balance = new_bal where id = p_to;
  date_txt := to_char(now(), 'DD/MM/YYYY HH24:MI:SS');
  insert into ledger (date, uname, type, amount, detail, ts)
  values (date_txt, u.name, case when p_sign > 0 then 'Recarga' else 'Retiro' end, p_sign * p_amount,
          'Ajuste del administrador', p_now);
end $$;

create or replace function public.admin_delete_user(p_token text, p_user_id text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare a users; nm text; adm boolean;
begin
  a := public._sess_user(p_token);
  if a.id is null or not a.admin then raise exception 'Solo el administrador puede eliminar usuarios.'; end if;
  select name, admin into nm, adm from users where id = p_user_id;
  if nm is null then raise exception 'Ese usuario no existe.'; end if;
  if adm then raise exception 'No puedes eliminar una cuenta de administración.'; end if;
  if p_user_id = a.id then raise exception 'No puedes eliminarte a ti mismo.'; end if;
  delete from bets where user_id = p_user_id;
  delete from ledger where uname = nm;
  update rounds set participants = coalesce((
      select jsonb_agg(e) from jsonb_array_elements(participants) e where e->>'id' <> p_user_id
    ), '[]'::jsonb)
    where jsonb_typeof(participants) = 'array';
  delete from users where id = p_user_id;
  return jsonb_build_object('ok', true, 'name', nm);
end $$;

create or replace function public.admin_user_stats(p_token text, p_user_id text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  a users; u users; bytype jsonb; last jsonb; won int := 0; lost int := 0;
  recargas int := 0; retiros int := 0; trans int := 0; tot int := 0;
  bets_agg jsonb; rw jsonb;
begin
  a := public._sess_user(p_token);
  if a.id is null or not a.admin then raise exception 'Solo el administrador.'; end if;
  select * into u from users where id = p_user_id;
  if u.id is null then raise exception 'Ese usuario no existe.'; end if;
  bytype := coalesce((
    select jsonb_agg(jsonb_build_object('type', t.type, 'count', t.n, 'sum', t.s) order by t.s desc)
    from (select type, count(*) n, coalesce(sum(amount),0) s from ledger where uname = u.name group by type) t
  ), '[]'::jsonb);
  select
    coalesce(sum(case when type not in ('Recarga','Retiro','Transferencia','Transferencia recibida') and amount > 0 then amount else 0 end),0),
    coalesce(sum(case when type not in ('Recarga','Retiro','Transferencia','Transferencia recibida') and amount < 0 then amount else 0 end),0),
    coalesce(sum(case when type = 'Recarga' then amount else 0 end),0),
    coalesce(sum(case when type = 'Retiro' then amount else 0 end),0),
    coalesce(sum(case when type in ('Transferencia','Transferencia recibida') then amount else 0 end),0),
    coalesce(sum(amount),0)
   into won, lost, recargas, retiros, trans, tot
   from ledger where uname = u.name;
  bets_agg := (select jsonb_build_object(
      'count', count(*), 'staked', coalesce(sum(stake),0), 'payout', coalesce(sum(payout),0),
      'won', count(*) filter (where status='won'), 'lost', count(*) filter (where status='lost'),
      'open', count(*) filter (where status='open'))
    from bets where user_id = p_user_id);
  rw := (select jsonb_build_object('games', count(*), 'prize', coalesce(sum(prize),0))
         from rounds where winner_id = p_user_id);
  last := coalesce((
    select jsonb_agg(jsonb_build_object('date', x.date, 'type', x.type, 'amount', x.amount, 'detail', x.detail, 'ts', x.ts) order by x.ts desc)
    from (select date, type, amount, detail, ts from ledger where uname = u.name order by ts desc limit 60) x
  ), '[]'::jsonb);
  return jsonb_build_object(
    'id', u.id, 'num', u.num, 'name', u.name, 'balance', u.balance, 'admin', u.admin,
    'created', u.created, 'avatar', u.avatar,
    'won', won, 'lost', lost, 'gameNet', won + lost,
    'recargas', recargas, 'retiros', retiros, 'transferencias', trans, 'net', tot,
    'byType', bytype, 'bets', bets_agg, 'rounds', rw, 'last', last);
end $$;

create or replace function public.admin_users_list(p_token text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare a users;
begin
  a := public._sess_user(p_token);
  if a.id is null or not a.admin then raise exception 'Solo el administrador.'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object('id', id, 'num', num, 'name', name,
             'balance', balance, 'admin', admin, 'created', created)
           order by created desc, num desc)
    from users), '[]'::jsonb);
end $$;

create or replace function public.admin_agent_list(p_token text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare a users;
begin
  a := public._sess_user(p_token);
  if a.id is null or not a.admin then raise exception 'Solo el administrador.'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', a2.id, 'num', a2.num, 'name', a2.name, 'code', a2.agent_code,
      'commission', a2.commission, 'commission_paid', a2.commission_paid,
      'players_count', (select count(*) from users u where u.agent_id = a2.id),
      'players_balance', coalesce((select sum(balance) from users u where u.agent_id = a2.id), 0),
      'house_profit', coalesce((select sum(profit) from agent_commission where agent_id = a2.id), 0),
      'players', coalesce((
        select jsonb_agg(jsonb_build_object('id', u.id, 'num', u.num, 'name', u.name, 'balance', u.balance) order by u.created desc)
        from users u where u.agent_id = a2.id), '[]'::jsonb)
    ) order by a2.num)
    from users a2 where a2.agent), '[]'::jsonb);
end $$;

create or replace function public.admin_agent_set(p_token text, p_user_id text, p_is_agent boolean, p_commission integer, p_code text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare a users; u users; c text;
begin
  a := public._sess_user(p_token);
  if a.id is null or not a.admin then raise exception 'Solo el administrador.'; end if;
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

create or replace function public.admin_agent_assign(p_token text, p_player text, p_agent text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare a users; pl users;
begin
  a := public._sess_user(p_token);
  if a.id is null or not a.admin then raise exception 'Solo el administrador.'; end if;
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

create or replace function public.admin_daily_profit(p_token text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare a users;
begin
  a := public._sess_user(p_token);
  if a.id is null or not a.admin then raise exception 'Solo el administrador.'; end if;
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

-- ---------- agentes ----------

create or replace function public.agent_summary(p_token text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare ag users; pl int; tot bigint; earned bigint; pend bigint;
begin
  ag := public._sess_user(p_token);
  if ag.id is null or not ag.agent then return jsonb_build_object('is_agent', false); end if;
  perform public.agent_commission_refresh(ag.id);
  select count(*), coalesce(sum(balance),0) into pl, tot from users where agent_id = ag.id;
  select coalesce(sum(commission),0) into earned from agent_commission where agent_id = ag.id;
  pend := greatest(0, earned - ag.commission_paid);
  return jsonb_build_object('is_agent', true, 'code', ag.agent_code, 'commission', ag.commission,
    'players', pl, 'managed_balance', tot,
    'earned', earned, 'paid', ag.commission_paid, 'pending', pend);
end $$;

create or replace function public.agent_players(p_token text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare ag users;
begin
  ag := public._sess_user(p_token);
  if ag.id is null or not ag.agent then raise exception 'No eres agente.'; end if;
  perform public.agent_commission_refresh(ag.id);
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', u.id, 'num', u.num, 'name', u.name, 'avatar', u.avatar,
      'balance', u.balance, 'created', u.created,
      'today', coalesce((select ac.commission from agent_commission ac
                         where ac.agent_id = ag.id and ac.player_id = u.id and ac.day = current_date), 0),
      'net', coalesce((
        select sum(amount) from ledger where uname = u.name
          and type not in ('Recarga','Retiro','Transferencia','Transferencia recibida')), 0))
      order by u.created desc, u.num desc)
    from users u where u.agent_id = ag.id), '[]'::jsonb);
end $$;

create or replace function public.agent_player_stats(p_token text, p_player text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  ag users; u users; bytype jsonb; last jsonb; won int := 0; lost int := 0; tot int := 0;
begin
  ag := public._sess_user(p_token);
  if ag.id is null or not ag.agent then raise exception 'No eres agente.'; end if;
  select * into u from users where id = p_player;
  if u.id is null then raise exception 'Ese jugador no existe.'; end if;
  if u.agent_id is distinct from ag.id then
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

create or replace function public.agent_pay_commission(p_token text, p_now bigint)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare ag users; earned bigint; pend bigint;
begin
  ag := public._sess_user(p_token);
  if ag.id is null or not ag.agent then raise exception 'No eres agente.'; end if;
  select * into ag from users where id = ag.id for update;
  perform public.agent_commission_refresh(ag.id);
  select coalesce(sum(commission),0) into earned from agent_commission where agent_id = ag.id;
  pend := greatest(0, earned - ag.commission_paid);
  if pend > 0 then
    update users set balance = balance + pend, commission_paid = commission_paid + pend where id = ag.id;
    insert into ledger (date, uname, type, amount, detail, ts)
    values (to_char(now(), 'DD/MM/YYYY HH24:MI:SS'), ag.name, 'Comisión agente', pend,
            'Comisión por tus jugadores afiliados', p_now);
  end if;
  return jsonb_build_object('paid', pend);
end $$;

create or replace function public.agent_commission_report(p_token text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare ag users; byday jsonb; bypd jsonb; tot_c bigint;
begin
  ag := public._sess_user(p_token);
  if ag.id is null or not ag.agent then raise exception 'No eres agente.'; end if;
  perform public.agent_commission_refresh(ag.id);
  select coalesce(sum(commission),0) into tot_c from agent_commission where agent_id = ag.id;
  select coalesce(jsonb_agg(jsonb_build_object('day', d.day, 'players', d.players, 'commission', d.commission) order by d.day desc), '[]'::jsonb)
    into byday from (
      select day, count(distinct player_id)::int as players, sum(commission)::bigint as commission
      from agent_commission where agent_id = ag.id group by day
    ) d;
  select coalesce(jsonb_agg(jsonb_build_object('day', x.day, 'id', p.id, 'num', p.num, 'name', p.name, 'commission', x.commission) order by x.day desc, x.commission desc, p.num), '[]'::jsonb)
    into bypd from (
      select day, player_id, commission from agent_commission where agent_id = ag.id
    ) x join users p on p.id = x.player_id;
  return jsonb_build_object('rate', ag.commission, 'total_commission', tot_c,
    'by_day', byday, 'by_player_day', bypd);
end $$;

-- ---------- apuestas ----------

create or replace function public.bets_list(p_token text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare u users; v_bal int; v_upd bigint; evs jsonb; mine jsonb;
begin
  u := public._sess_user(p_token);
  if u.id is null then return jsonb_build_object('balance',0,'updated',null,'events','[]'::jsonb,'mine','[]'::jsonb); end if;
  v_bal := u.balance;
  select updated into v_upd from bet_config where id = 1;
  select coalesce(jsonb_agg(j order by ct), '[]'::jsonb) into evs
  from (
    select e.commence_time as ct,
      jsonb_build_object(
        'id', e.id, 'sport', e.sport_title, 'home', e.home, 'away', e.away,
        'commence', (extract(epoch from e.commence_time) * 1000)::bigint,
        'oh', e.odds_home, 'od', e.odds_draw, 'oa', e.odds_away,
        'status', e.status, 'result', e.result,
        'mine', (select jsonb_build_object('pick', b.pick, 'pick_name', b.pick_name,
                    'stake', b.stake, 'odds', b.odds, 'status', b.status, 'payout', b.payout)
                 from bets b where b.event_id = e.id and b.user_id = u.id
                 order by b.created desc limit 1)) as j
    from bet_event e
    where (e.status = 'open' and e.commence_time > now() - interval '10 minutes')
       or (e.status <> 'open' and e.commence_time > now() - interval '4 days')
  ) t;
  select coalesce(jsonb_agg(j order by cr), '[]'::jsonb) into mine
  from (
    select b.created as cr,
      jsonb_build_object(
        'id', b.id, 'home', e.home, 'away', e.away, 'sport', e.sport_title,
        'pick_name', b.pick_name, 'stake', b.stake, 'odds', b.odds,
        'status', b.status, 'payout', b.payout, 'created', b.created,
        'result', e.result) as j
    from bets b join bet_event e on e.id = b.event_id
    where b.user_id = u.id
  ) t;
  return jsonb_build_object('balance', v_bal, 'updated', v_upd, 'events', evs, 'mine', mine);
end $$;

create or replace function public.bets_place(p_token text, p_event text, p_pick text, p_stake integer, p_now bigint)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare u users; ev bet_event; v_odds numeric; v_pickname text; date_txt text;
begin
  u := public._sess_user(p_token);
  if u.id is null then raise exception 'Sesión expirada. Cierra y vuelve a entrar.'; end if;
  select * into u from users where id = u.id for update;
  if u.admin then raise exception 'La cuenta de administración no puede apostar.'; end if;
  if p_stake is null or p_stake <= 0 then raise exception 'Monto de apuesta no válido.'; end if;
  select * into ev from bet_event where id = p_event;
  if not found then raise exception 'Ese partido no existe.'; end if;
  if ev.status <> 'open' then raise exception 'Ese partido ya cerró las apuestas.'; end if;
  if now() >= ev.commence_time then raise exception 'El partido ya empezó. Espera el próximo.'; end if;
  if p_pick = 'home' then v_odds := ev.odds_home; v_pickname := ev.home || ' gana';
  elsif p_pick = 'away' then v_odds := ev.odds_away; v_pickname := ev.away || ' gana';
  elsif p_pick = 'draw' then v_odds := ev.odds_draw; v_pickname := 'Empate';
  else raise exception 'Pronóstico no válido.'; end if;
  if v_odds is null then raise exception 'Ese pronóstico no está disponible.'; end if;
  if u.balance < p_stake then raise exception 'No tienes suficientes fichas (% disponibles).', u.balance; end if;
  update users set balance = balance - p_stake where id = u.id;
  insert into bets (user_id, event_id, pick, pick_name, stake, odds, status, created)
  values (u.id, p_event, p_pick, v_pickname, p_stake, v_odds, 'open', p_now);
  date_txt := to_char(now(), 'DD/MM/YYYY HH24:MI:SS');
  insert into ledger (date, uname, type, amount, detail, ts)
  values (date_txt, u.name, 'Apuesta', -p_stake,
          ev.home || ' vs ' || ev.away || ' — ' || v_pickname || ' x' || v_odds, p_now);
  return public.bets_list(p_token);
end $$;

create or replace function public.bets_settle(p_token text, p_event text, p_result text, p_now bigint)
returns integer
language plpgsql
security definer
set search_path to 'public'
as $$
declare a users;
begin
  a := public._sess_user(p_token);
  if a.id is null or not a.admin then raise exception 'Solo el administrador puede liquidar partidos.'; end if;
  return public._bet_settle_apply(p_event, p_result, p_now);
end $$;

create or replace function public.bets_void(p_token text, p_event text, p_now bigint)
returns integer
language plpgsql
security definer
set search_path to 'public'
as $$
declare a users;
begin
  a := public._sess_user(p_token);
  if a.id is null or not a.admin then raise exception 'Solo el administrador puede anular partidos.'; end if;
  return public._bet_void_apply(p_event, p_now);
end $$;

create or replace function public.bets_admin_setup(p_token text, p_key text, p_sports jsonb)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare a users;
begin
  a := public._sess_user(p_token);
  if a.id is null or not a.admin then raise exception 'Solo el administrador.'; end if;
  if p_key is not null and p_key <> '' then
    update bet_config set api_key = p_key where id = 1;
  end if;
  if p_sports is not null and jsonb_typeof(p_sports) = 'array' then
    update bet_config set sports = p_sports where id = 1;
  end if;
  return (select jsonb_build_object('sports', sports, 'updated', updated) from bet_config where id = 1);
end $$;

create or replace function public.bets_admin_refresh(p_token text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare a users;
begin
  a := public._sess_user(p_token);
  if a.id is null or not a.admin then raise exception 'Solo el administrador.'; end if;
  return public.bets_refresh_all();
end $$;

create or replace function public.bets_admin_settle(p_token text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare a users;
begin
  a := public._sess_user(p_token);
  if a.id is null or not a.admin then raise exception 'Solo el administrador.'; end if;
  return public.bets_settle_all();
end $$;

-- ---------- juegos ----------

create or replace function public.join_round(p_round text, p_token text, p_cost integer, p_label text, p_now bigint)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare u users; r rounds; ps jsonb;
begin
  u := public._sess_user(p_token);
  if u.id is null then raise exception 'Sesión expirada. Cierra y vuelve a entrar.'; end if;
  select * into u from users where id = u.id for update;
  select * into r from rounds where id = p_round for update;
  if not found then raise exception 'La ronda se está cargando.'; end if;
  if r.finished or p_now >= r.ends then
    raise exception 'La ronda está terminando. Espera la siguiente.';
  end if;
  ps := r.participants;
  if exists (select 1 from jsonb_array_elements(ps) e where e->>'id' = u.id) then
    raise exception 'Ya estás participando en esta ronda.';
  end if;
  if u.balance < p_cost then
    raise exception 'No tienes suficientes fichas. Necesitas % fichas.', p_cost;
  end if;
  update users set balance = balance - p_cost where id = u.id;
  update rounds set participants = ps || jsonb_build_array(jsonb_build_object('id', u.id, 'name', u.name)) where id = p_round;
  insert into ledger (date, uname, type, amount, detail, ts)
  values (to_char(now(), 'DD/MM/YYYY HH24:MI:SS'), u.name, p_label, -p_cost, 'Participación en ' || lower(p_label), p_now);
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.scratch_buy(p_token text, p_price integer, p_now bigint)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  u users; s scratch_stats%rowtype; budget int; prize int; rr int; new_bal int; date_txt text;
begin
  u := public._sess_user(p_token);
  if u.id is null then raise exception 'Sesión expirada. Cierra y vuelve a entrar.'; end if;
  select * into u from users where id = u.id for update;
  if u.balance < p_price then raise exception 'No tienes suficientes fichas. Necesitas % fichas.', p_price; end if;
  select * into s from scratch_stats where id = 1 for update;
  if not found then
    insert into scratch_stats (id, cards, bets, paid) values (1, 0, 0, 0) returning * into s;
  end if;
  budget := greatest(0, floor(((s.bets + p_price) * 0.9) - s.paid));
  rr := floor(random() * 1000);
  if rr < 683 then prize := 0;
  elsif rr < 873 then prize := 10;
  elsif rr < 953 then prize := 20;
  elsif rr < 983 then prize := 50;
  elsif rr < 993 then prize := 100;
  elsif rr < 998 then prize := 200;
  else prize := 1000; end if;
  if prize > budget then
    prize := case
      when budget >= 1000 then 1000
      when budget >= 200 then 200
      when budget >= 100 then 100
      when budget >= 50 then 50
      when budget >= 20 then 20
      when budget >= 10 then 10
      else 0 end;
  end if;
  new_bal := u.balance - p_price + prize;
  update users set balance = new_bal where id = u.id;
  update scratch_stats set cards = cards + 1, bets = bets + p_price, paid = paid + prize where id = 1;
  date_txt := to_char(now(), 'DD/MM/YYYY HH24:MI:SS');
  insert into ledger (date, uname, type, amount, detail, ts)
  values (date_txt, u.name, 'Raspa y Gana', -p_price, 'Compra de cartón', p_now);
  if prize > 0 then
    insert into ledger (date, uname, type, amount, detail, ts)
    values (date_txt, u.name, 'Raspa y Gana - Premio', prize, 'Cartón premiado: ' || prize || ' fichas', p_now + 1);
  end if;
  return jsonb_build_object('prize', prize, 'new_bal', new_bal);
end $$;

-- ============================================================
-- Cierre de permisos: quitar EXECUTE por defecto (PUBLIC) a los
-- internos y a lo que ya no debe llamarse desde el cliente.
-- ============================================================

revoke all on function public._bet_settle_apply(text, text, bigint) from public, anon, authenticated;
revoke all on function public._bet_void_apply(text, bigint) from public, anon, authenticated;
revoke all on function public.agent_commission_refresh(text) from public, anon, authenticated;
revoke all on function public.bets_refresh(text) from public, anon, authenticated;
revoke all on function public.bets_refresh_all() from public, anon, authenticated;
revoke all on function public.bets_settle_all() from public, anon, authenticated;
revoke all on function public.bets_settle_sport(text) from public, anon, authenticated;

revoke all on function public.trio_advance(bigint) from public, anon, authenticated;
revoke all on function public.trio_best(jsonb) from public, anon, authenticated;
revoke all on function public.trio_bet(text, integer, bigint) from public, anon, authenticated;
revoke all on function public.trio_cmp(jsonb, jsonb) from public, anon, authenticated;
revoke all on function public.trio_deal(text) from public, anon, authenticated;
revoke all on function public.trio_deck() from public, anon, authenticated;
revoke all on function public.trio_eval(jsonb) from public, anon, authenticated;
revoke all on function public.trio_fold(text, bigint) from public, anon, authenticated;
revoke all on function public.trio_join(text) from public, anon, authenticated;
revoke all on function public.trio_lab(integer) from public, anon, authenticated;
revoke all on function public.trio_leave(text) from public, anon, authenticated;
revoke all on function public.trio_pay(text, integer) from public, anon, authenticated;
revoke all on function public.trio_pay_pot() from public, anon, authenticated;
revoke all on function public.trio_reset(text) from public, anon, authenticated;
revoke all on function public.trio_state(text) from public, anon, authenticated;
revoke all on function public.trio_tick(bigint) from public, anon, authenticated;

-- ============================================================
-- Permisos del cliente (whitelist)
-- ============================================================

grant execute on function public.login(text, text) to anon, authenticated;
grant execute on function public.register_user(text, text, text, integer, boolean, bigint) to anon, authenticated;
grant execute on function public.get_user(text) to anon, authenticated;
grant execute on function public.change_password(text, text) to anon, authenticated;
grant execute on function public.set_avatar(text, text) to anon, authenticated;
grant execute on function public.apply_referral(text, text) to anon, authenticated;
grant execute on function public.send_fichas(text, text, integer, bigint) to anon, authenticated;

grant execute on function public.admin_adjust(text, text, integer, integer, bigint) to anon, authenticated;
grant execute on function public.admin_delete_user(text, text) to anon, authenticated;
grant execute on function public.admin_user_stats(text, text) to anon, authenticated;
grant execute on function public.admin_users_list(text) to anon, authenticated;
grant execute on function public.admin_agent_list(text) to anon, authenticated;
grant execute on function public.admin_agent_set(text, text, boolean, integer, text) to anon, authenticated;
grant execute on function public.admin_agent_assign(text, text, text) to anon, authenticated;
grant execute on function public.admin_daily_profit(text) to anon, authenticated;

grant execute on function public.agent_summary(text) to anon, authenticated;
grant execute on function public.agent_players(text) to anon, authenticated;
grant execute on function public.agent_player_stats(text, text) to anon, authenticated;
grant execute on function public.agent_pay_commission(text, bigint) to anon, authenticated;
grant execute on function public.agent_commission_report(text) to anon, authenticated;

grant execute on function public.bets_list(text) to anon, authenticated;
grant execute on function public.bets_place(text, text, text, integer, bigint) to anon, authenticated;
grant execute on function public.bets_settle(text, text, text, bigint) to anon, authenticated;
grant execute on function public.bets_void(text, text, bigint) to anon, authenticated;
grant execute on function public.bets_admin_setup(text, text, jsonb) to anon, authenticated;
grant execute on function public.bets_admin_refresh(text) to anon, authenticated;
grant execute on function public.bets_admin_settle(text) to anon, authenticated;

grant execute on function public.join_round(text, text, integer, text, bigint) to anon, authenticated;
grant execute on function public.scratch_buy(text, integer, bigint) to anon, authenticated;

grant execute on function public.ensure_round(text, bigint, bigint, bigint) to anon, authenticated;
grant execute on function public.settle_round(text, text, integer, bigint) to anon, authenticated;
