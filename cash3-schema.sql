-- ============================================================
-- CASH 3 (banca manual): el admin escribe el número ganador.
-- Modalidades elegidas por el jugador antes de apostar:
--   'three' (a las 3): 3 dígitos exactos  -> paga mult_three por ficha
--   'two'   (últimos 2): 2 dígitos = últimos 2 -> paga mult_two por ficha
-- ============================================================

create table if not exists public.cash3_config (
  id int primary key,
  mult_three int not null default 400,
  mult_two int not null default 70
);
insert into public.cash3_config (id) values (1) on conflict (id) do nothing;

create table if not exists public.cash3_round (
  id text primary key,
  opened bigint not null default 0,
  finished boolean not null default false,
  winner text,
  settled bigint,
  total_staked bigint not null default 0,
  total_paid bigint not null default 0
);
create index if not exists cash3_round_open_idx on public.cash3_round(finished, opened desc);

create table if not exists public.cash3_bet (
  id bigserial primary key,
  round_id text not null,
  user_id text not null,
  uname text not null,
  num text not null,
  mode text not null,
  stake integer not null,
  status text not null default 'open',
  payout integer not null default 0,
  created bigint not null default 0
);
create index if not exists cash3_bet_round_idx on public.cash3_bet(round_id);
create index if not exists cash3_bet_user_idx on public.cash3_bet(user_id, created desc);

alter table public.cash3_config enable row level security;
alter table public.cash3_round enable row level security;
alter table public.cash3_bet enable row level security;

-- ---------- interno ----------

create or replace function public._cash3_open_round(p_now bigint)
returns text
language plpgsql
security definer
set search_path to 'public'
as $$
declare rid text;
begin
  select id into rid from cash3_round where finished = false order by opened desc limit 1;
  if rid is null then
    rid := 'c3_' || to_char(now(), 'YYYYMMDDHH24MISS') || '_' || substr(md5(random()::text), 1, 6);
    insert into cash3_round (id, opened, finished) values (rid, p_now, false);
  end if;
  return rid;
end $$;

revoke all on function public._cash3_open_round(bigint) from public, anon, authenticated;

-- ---------- jugador ----------

create or replace function public.cash3_state(p_token text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  u users; rid text; r cash3_round; cfg cash3_config;
  mine jsonb; recent jsonb; hist jsonb;
begin
  u := public._sess_user(p_token);
  if u.id is null then raise exception 'Sesión expirada. Cierra y vuelve a entrar.'; end if;
  select * into cfg from cash3_config where id = 1;
  rid := public._cash3_open_round((extract(epoch from now()) * 1000)::bigint);
  select * into r from cash3_round where id = rid;
  select coalesce(jsonb_agg(jsonb_build_object('id', b.id, 'num', b.num, 'mode', b.mode, 'stake', b.stake,
           'status', b.status, 'payout', b.payout, 'created', b.created) order by b.created desc), '[]'::jsonb)
    into mine
    from cash3_bet b where b.round_id = rid and b.user_id = u.id and b.status = 'open';
  select coalesce(jsonb_agg(jsonb_build_object('num', x.num, 'mode', x.mode, 'stake', x.stake,
           'status', x.status, 'payout', x.payout, 'winner', x.winner, 'created', x.created) order by x.created desc), '[]'::jsonb)
    into recent
    from (select b.num, b.mode, b.stake, b.status, b.payout, b.created, r2.winner
          from cash3_bet b left join cash3_round r2 on r2.id = b.round_id
          where b.user_id = u.id order by b.created desc limit 25) x;
  select coalesce(jsonb_agg(jsonb_build_object('winner', h.winner, 'settled', h.settled,
           'total_staked', h.total_staked, 'total_paid', h.total_paid) order by h.settled desc), '[]'::jsonb)
    into hist
    from (select winner, settled, total_staked, total_paid from cash3_round
          where finished and winner is not null order by settled desc limit 15) h;
  return jsonb_build_object(
    'round', rid, 'opened', r.opened, 'balance', u.balance,
    'mult_three', cfg.mult_three, 'mult_two', cfg.mult_two,
    'mine', mine, 'recent', recent, 'history', hist);
end $$;

create or replace function public.cash3_place(p_token text, p_num text, p_mode text, p_stake integer, p_now bigint)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare u users; r cash3_round; rid text; vnum text; date_txt text;
begin
  u := public._sess_user(p_token);
  if u.id is null then raise exception 'Sesión expirada. Cierra y vuelve a entrar.'; end if;
  select * into u from users where id = u.id for update;
  if u.admin then raise exception 'La cuenta de administración no puede apostar.'; end if;
  if p_stake is null or p_stake <= 0 then raise exception 'Monto no válido.'; end if;
  vnum := regexp_replace(coalesce(p_num, ''), '[^0-9]', '', 'g');
  if p_mode = 'three' then
    if length(vnum) < 1 or length(vnum) > 3 then raise exception 'Escribe de 1 a 3 dígitos.'; end if;
    vnum := lpad(vnum, 3, '0');
  elsif p_mode = 'two' then
    if length(vnum) < 1 or length(vnum) > 2 then raise exception 'Escribe 1 o 2 dígitos.'; end if;
    vnum := lpad(vnum, 2, '0');
  else
    raise exception 'Modalidad no válida.';
  end if;
  if u.balance < p_stake then raise exception 'No tienes suficientes fichas (% disponibles).', u.balance; end if;
  rid := public._cash3_open_round(p_now);
  select * into r from cash3_round where id = rid for update;
  if r.finished then raise exception 'La ronda acaba de cerrar. Vuelve a intentarlo.'; end if;
  update users set balance = balance - p_stake where id = u.id;
  insert into cash3_bet (round_id, user_id, uname, num, mode, stake, status, payout, created)
  values (rid, u.id, u.name, vnum, p_mode, p_stake, 'open', 0, p_now);
  date_txt := to_char(now(), 'DD/MM/YYYY HH24:MI:SS');
  insert into ledger (date, uname, type, amount, detail, ts)
  values (date_txt, u.name, 'Cash 3', -p_stake,
          case when p_mode = 'three' then 'A las 3: ' || vnum else 'Últimos 2: ' || vnum end, p_now);
  return jsonb_build_object('ok', true, 'num', vnum, 'mode', p_mode, 'balance', u.balance - p_stake);
end $$;

-- ---------- admin ----------

create or replace function public.cash3_admin_info(p_token text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare a users; rid text; bets jsonb; tot bigint; bynum jsonb;
begin
  a := public._sess_user(p_token);
  if a.id is null or not a.admin then raise exception 'Solo el administrador.'; end if;
  rid := public._cash3_open_round((extract(epoch from now()) * 1000)::bigint);
  select coalesce(sum(stake), 0) into tot from cash3_bet where round_id = rid and status = 'open';
  select coalesce(jsonb_agg(jsonb_build_object('num', b.num, 'mode', b.mode, 'stake', b.stake,
           'name', b.uname, 'created', b.created) order by b.created desc), '[]'::jsonb)
    into bets from cash3_bet b where b.round_id = rid and b.status = 'open';
  select coalesce(jsonb_agg(jsonb_build_object('num', t.num, 'mode', t.mode, 'count', t.n, 'stake', t.s) order by t.s desc), '[]'::jsonb)
    into bynum from (
      select num, mode, count(*) n, sum(stake) s from cash3_bet
      where round_id = rid and status = 'open' group by num, mode
    ) t;
  return jsonb_build_object('round', rid, 'open_stake', tot, 'bets', bets, 'by_num', bynum);
end $$;

create or replace function public.cash3_admin_settle(p_token text, p_winner text, p_now bigint)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  a users; cfg cash3_config; w text; rid text; r cash3_round; b record;
  pay int; won_cnt int := 0; lost_cnt int := 0; tot_stake bigint := 0; tot_paid bigint := 0;
  date_txt text;
begin
  a := public._sess_user(p_token);
  if a.id is null or not a.admin then raise exception 'Solo el administrador.'; end if;
  w := regexp_replace(coalesce(p_winner, ''), '[^0-9]', '', 'g');
  if length(w) < 1 or length(w) > 3 then raise exception 'Escribe el número ganador (1 a 3 dígitos).'; end if;
  w := lpad(w, 3, '0');
  select * into cfg from cash3_config where id = 1;
  select id into rid from cash3_round where finished = false order by opened desc limit 1;
  if rid is null then raise exception 'No hay una ronda abierta.'; end if;
  select * into r from cash3_round where id = rid for update;
  if r.finished then raise exception 'Esa ronda ya se liquidó.'; end if;
  date_txt := to_char(now(), 'DD/MM/YYYY HH24:MI:SS');
  for b in select * from cash3_bet where round_id = rid and status = 'open' order by created for update loop
    tot_stake := tot_stake + b.stake;
    pay := 0;
    if b.mode = 'three' then
      if b.num = w then pay := b.stake * cfg.mult_three; end if;
    elsif b.mode = 'two' then
      if b.num = right(w, 2) then pay := b.stake * cfg.mult_two; end if;
    end if;
    if pay > 0 then
      won_cnt := won_cnt + 1; tot_paid := tot_paid + pay;
      update cash3_bet set status = 'won', payout = pay where id = b.id;
      update users set balance = balance + pay where id = b.user_id;
      insert into ledger (date, uname, type, amount, detail, ts)
      values (date_txt, b.uname, 'Cash 3 - Premio', pay,
              case when b.mode = 'three' then 'A las 3: ' || b.num || ' (x' || cfg.mult_three || ')'
                   else 'Últimos 2: ' || b.num || ' (x' || cfg.mult_two || ')' end, p_now);
    else
      lost_cnt := lost_cnt + 1;
      update cash3_bet set status = 'lost', payout = 0 where id = b.id;
    end if;
  end loop;
  update cash3_round set finished = true, winner = w, settled = p_now,
    total_staked = tot_stake, total_paid = tot_paid where id = rid;
  perform public._cash3_open_round(p_now);
  return jsonb_build_object('ok', true, 'winner', w, 'won', won_cnt, 'lost', lost_cnt,
    'total_staked', tot_stake, 'total_paid', tot_paid, 'net', tot_stake - tot_paid);
end $$;

grant execute on function public.cash3_state(text) to anon, authenticated;
grant execute on function public.cash3_place(text, text, text, integer, bigint) to anon, authenticated;
grant execute on function public.cash3_admin_info(text) to anon, authenticated;
grant execute on function public.cash3_admin_settle(text, text, bigint) to anon, authenticated;
