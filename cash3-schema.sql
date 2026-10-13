-- ============================================================
-- CASH 3 (banca manual): el admin escribe el número ganador.
-- Cada jugada = un número de 3 dígitos con DOS montos a la vez:
--   p_stake_three -> si el número sale exacto, paga mult_three por ficha
--   p_stake_two   -> si coinciden los últimos 2, paga mult_two por ficha
-- Ejemplo: "217-3-5" = número 217, 3 fichas a las 3, 5 fichas a los últimos 2.
-- Si sale 217, gana AMBAS (3*mult_three + 5*mult_two).
-- ============================================================

create table if not exists public.cash3_config (
  id int primary key,
  mult_three int not null default 400,
  mult_two int not null default 70,
  max_three bigint not null default 0,
  max_two bigint not null default 0
);
insert into public.cash3_config (id) values (1) on conflict (id) do nothing;
alter table public.cash3_config add column if not exists max_three bigint not null default 0;
alter table public.cash3_config add column if not exists max_two bigint not null default 0;
alter table public.cash3_config drop column if exists max_per_num;

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
  stake_three integer not null default 0,
  stake_two integer not null default 0,
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
  select coalesce(jsonb_agg(jsonb_build_object('id', b.id, 'num', b.num,
           'stake_three', b.stake_three, 'stake_two', b.stake_two,
           'status', b.status, 'payout', b.payout, 'created', b.created) order by b.created desc), '[]'::jsonb)
    into mine
    from cash3_bet b where b.round_id = rid and b.user_id = u.id and b.status = 'open';
  select coalesce(jsonb_agg(jsonb_build_object('num', x.num, 'stake_three', x.stake_three,
           'stake_two', x.stake_two, 'status', x.status, 'payout', x.payout,
           'winner', x.winner, 'created', x.created) order by x.created desc), '[]'::jsonb)
    into recent
    from (select b.num, b.stake_three, b.stake_two, b.status, b.payout, b.created, r2.winner
          from cash3_bet b left join cash3_round r2 on r2.id = b.round_id
          where b.user_id = u.id order by b.created desc limit 25) x;
  select coalesce(jsonb_agg(jsonb_build_object('winner', h.winner, 'settled', h.settled,
           'total_staked', h.total_staked, 'total_paid', h.total_paid) order by h.settled desc), '[]'::jsonb)
    into hist
    from (select winner, settled, total_staked, total_paid from cash3_round
          where finished and winner is not null order by settled desc limit 15) h;
  return jsonb_build_object(
    'round', rid, 'opened', r.opened, 'balance', u.balance,
    'mult_three', cfg.mult_three, 'mult_two', cfg.mult_two, 'max_three', cfg.max_three, 'max_two', cfg.max_two,
    'mine', mine, 'recent', recent, 'history', hist);
end $$;

create or replace function public.cash3_place(p_token text, p_num text, p_stake_three integer, p_stake_two integer, p_now bigint)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare u users; r cash3_round; cfg cash3_config; rid text; vnum text; st3 int; st2 int; total int; cur3 bigint; cur2 bigint; date_txt text; detail_txt text;
begin
  u := public._sess_user(p_token);
  if u.id is null then raise exception 'Sesión expirada. Cierra y vuelve a entrar.'; end if;
  select * into u from users where id = u.id for update;
  if u.admin then raise exception 'La cuenta de administración no puede apostar.'; end if;
  select * into cfg from cash3_config where id = 1;
  st3 := greatest(coalesce(p_stake_three, 0), 0);
  st2 := greatest(coalesce(p_stake_two, 0), 0);
  total := st3 + st2;
  if total <= 0 then raise exception 'Escribe cuántas fichas a las 3 y/o a los últimos 2.'; end if;
  vnum := regexp_replace(coalesce(p_num, ''), '[^0-9]', '', 'g');
  if length(vnum) < 1 or length(vnum) > 3 then raise exception 'Escribe un número de 1 a 3 dígitos.'; end if;
  vnum := lpad(vnum, 3, '0');
  if u.balance < total then raise exception 'No tienes suficientes fichas (% disponibles).', u.balance; end if;
  rid := public._cash3_open_round(p_now);
  select * into r from cash3_round where id = rid for update;
  if r.finished then raise exception 'La ronda acaba de cerrar. Vuelve a intentarlo.'; end if;
  if st3 > 0 and cfg.max_three > 0 then
    select coalesce(sum(stake_three), 0) into cur3
      from cash3_bet where round_id = rid and num = vnum and status = 'open';
    if cur3 + st3 > cfg.max_three then
      raise exception 'El número % ya alcanzó el tope a las 3 (% fichas). Máximo que puedes apostar ahora en ese número: % fichas.',
        vnum, cfg.max_three, greatest(cfg.max_three - cur3, 0);
    end if;
  end if;
  if st2 > 0 and cfg.max_two > 0 then
    select coalesce(sum(stake_two), 0) into cur2
      from cash3_bet where round_id = rid and right(num, 2) = right(vnum, 2) and status = 'open';
    if cur2 + st2 > cfg.max_two then
      raise exception 'Los últimos 2 del número % (el %) ya alcanzaron el tope (% fichas). Máximo que puedes apostar ahí ahora: % fichas.',
        vnum, right(vnum, 2), cfg.max_two, greatest(cfg.max_two - cur2, 0);
    end if;
  end if;
  update users set balance = balance - total where id = u.id;
  insert into cash3_bet (round_id, user_id, uname, num, stake_three, stake_two, status, payout, created)
  values (rid, u.id, u.name, vnum, st3, st2, 'open', 0, p_now);
  detail_txt := vnum || case when st3 > 0 then ' · a las 3: ' || st3 else '' end
                      || case when st2 > 0 then ' · últimos 2: ' || st2 else '' end;
  date_txt := to_char(now(), 'DD/MM/YYYY HH24:MI:SS');
  insert into ledger (date, uname, type, amount, detail, ts)
  values (date_txt, u.name, 'Cash 3', -total, detail_txt, p_now);
  return jsonb_build_object('ok', true, 'num', vnum, 'stake_three', st3, 'stake_two', st2, 'balance', u.balance - total);
end $$;

-- ---------- admin ----------

create or replace function public.cash3_admin_info(p_token text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare a users; cfg cash3_config; rid text; bets jsonb; tot bigint; bynum jsonb; max3 bigint; max2 bigint;
begin
  a := public._sess_user(p_token);
  if a.id is null or not a.admin then raise exception 'Solo el administrador.'; end if;
  select * into cfg from cash3_config where id = 1;
  max3 := cfg.max_three; max2 := cfg.max_two;
  rid := public._cash3_open_round((extract(epoch from now()) * 1000)::bigint);
  select coalesce(sum(stake_three + stake_two), 0) into tot from cash3_bet where round_id = rid and status = 'open';
  select coalesce(jsonb_agg(jsonb_build_object('user_id', b.user_id, 'num', b.num, 'stake_three', b.stake_three, 'stake_two', b.stake_two,
           'stake', b.stake_three + b.stake_two, 'name', b.uname, 'created', b.created) order by b.created desc), '[]'::jsonb)
    into bets from cash3_bet b where b.round_id = rid and b.status = 'open';
  select coalesce(jsonb_agg(jsonb_build_object('num', t.num, 'count', t.n, 'stake', t.s,
           'stake_three', t.s3, 'stake_two', t.s2,
           'rem_three', case when max3 > 0 then greatest(max3 - t.s3, 0) else null end,
           'rem_two', case when max2 > 0 then greatest(max2 - t2.p2, 0) else null end) order by t.s desc), '[]'::jsonb)
    into bynum from (
      select b.num, count(*) n, sum(stake_three + stake_two) s, sum(stake_three) s3, sum(stake_two) s2
      from cash3_bet b where b.round_id = rid and b.status = 'open' group by b.num
    ) t
    left join (
      select right(num, 2) combo, sum(stake_two) p2
      from cash3_bet where round_id = rid and status = 'open' group by right(num, 2)
    ) t2 on t2.combo = right(t.num, 2);
  return jsonb_build_object('round', rid, 'open_stake', tot, 'bets', bets, 'by_num', bynum,
    'max_three', max3, 'max_two', max2);
end $$;

create or replace function public.cash3_admin_config(p_token text, p_max_three bigint, p_max_two bigint)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare a users; v3 bigint; v2 bigint;
begin
  a := public._sess_user(p_token);
  if a.id is null or not a.admin then raise exception 'Solo el administrador.'; end if;
  v3 := greatest(coalesce(p_max_three, 0), 0);
  v2 := greatest(coalesce(p_max_two, 0), 0);
  update cash3_config set max_three = v3, max_two = v2 where id = 1;
  return jsonb_build_object('max_three', v3, 'max_two', v2);
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
  date_txt text; detail_txt text;
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
    tot_stake := tot_stake + b.stake_three + b.stake_two;
    pay := 0;
    if b.num = w then pay := pay + b.stake_three * cfg.mult_three; end if;
    if right(b.num, 2) = right(w, 2) then pay := pay + b.stake_two * cfg.mult_two; end if;
    if pay > 0 then
      won_cnt := won_cnt + 1; tot_paid := tot_paid + pay;
      update cash3_bet set status = 'won', payout = pay where id = b.id;
      update users set balance = balance + pay where id = b.user_id;
      detail_txt := b.num || ' → ' || w
        || case when b.num = w and b.stake_three > 0 then ' (a las 3: ' || (b.stake_three * cfg.mult_three) || ')' else '' end
        || case when right(b.num,2) = right(w,2) and b.stake_two > 0 then ' (últimos 2: ' || (b.stake_two * cfg.mult_two) || ')' else '' end;
      insert into ledger (date, uname, type, amount, detail, ts)
      values (date_txt, b.uname, 'Cash 3 - Premio', pay, detail_txt, p_now);
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
grant execute on function public.cash3_place(text, text, integer, integer, bigint) to anon, authenticated;
grant execute on function public.cash3_admin_info(text) to anon, authenticated;
grant execute on function public.cash3_admin_settle(text, text, bigint) to anon, authenticated;
grant execute on function public.cash3_admin_config(text, bigint, bigint) to anon, authenticated;
