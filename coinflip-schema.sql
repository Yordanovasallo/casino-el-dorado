-- ================================================================
-- Cara o Cruz - juego instantáneo (la casa cobra su edificio por
-- el múltiplo: ej. paga 1.9x por cada ficha apostada)
-- ================================================================

create table if not exists public.coinflip_config(
  id integer primary key check (id = 1),
  mult numeric not null default 1.9 check (mult > 1),
  max_bet bigint not null default 200
);

create table if not exists public.coinflip_bet(
  id bigserial primary key,
  user_id text,
  uname text,
  choice text,
  stake integer,
  result text,
  won boolean,
  payout integer default 0,
  created bigint
);
create index if not exists coinflip_bet_user_idx on public.coinflip_bet(user_id);
create index if not exists coinflip_bet_created_idx on public.coinflip_bet(created desc);

create table if not exists public.coinflip_stats(
  id integer primary key check (id = 1),
  flips bigint not null default 0,
  bets bigint not null default 0,
  paid bigint not null default 0
);

insert into public.coinflip_config (id) values (1) on conflict (id) do nothing;
insert into public.coinflip_stats (id) values (1) on conflict (id) do nothing;

alter table public.coinflip_config enable row level security;
alter table public.coinflip_stats enable row level security;
alter table public.coinflip_bet enable row level security;

-- ---------- estado para el jugador ----------
create or replace function public.coinflip_state(p_token text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  u users; cfg coinflip_config; stats coinflip_stats;
  mine jsonb; recent jsonb;
begin
  u := public._sess_user(p_token);
  if u.id is null then raise exception 'Sesión expirada. Cierra y vuelve a entrar.'; end if;
  select * into cfg from coinflip_config where id = 1;
  select * into stats from coinflip_stats where id = 1;
  select coalesce(jsonb_agg(jsonb_build_object('id', b.id, 'choice', b.choice, 'stake', b.stake,
           'result', b.result, 'won', b.won, 'payout', b.payout, 'created', b.created) order by b.created desc), '[]'::jsonb)
    into mine from (select * from coinflip_bet where user_id = u.id order by created desc limit 20) b;
  select coalesce(jsonb_agg(jsonb_build_object('id', b.id, 'uname', b.uname, 'choice', b.choice,
           'stake', b.stake, 'result', b.result, 'won', b.won, 'payout', b.payout, 'created', b.created) order by b.created desc), '[]'::jsonb)
    into recent from (select * from coinflip_bet order by created desc limit 20) b;
  return jsonb_build_object('balance', u.balance, 'mult', cfg.mult, 'max_bet', cfg.max_bet,
    'flips', stats.flips, 'bets', stats.bets, 'paid', stats.paid, 'profit', stats.bets - stats.paid,
    'mine', mine, 'recent', recent);
end $$;

-- ---------- lanzar la moneda ----------
create or replace function public.coinflip_flip(p_token text, p_choice text, p_stake integer, p_now bigint)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  u users; cfg coinflip_config; cchoice text; cresult text; won boolean; payout int; new_bal bigint; date_txt text;
begin
  u := public._sess_user(p_token);
  if u.id is null then raise exception 'Sesión expirada. Cierra y vuelve a entrar.'; end if;
  select * into cfg from coinflip_config where id = 1;
  cchoice := lower(trim(p_choice));
  if cchoice not in ('cara','cruz') then raise exception 'Elige Cara o Cruz.'; end if;
  if p_stake is null or p_stake < 1 then raise exception 'Escribe cuántas fichas quieres apostar (mínimo 1).'; end if;
  if p_stake > cfg.max_bet then raise exception 'Máximo por apuesta: % fichas.', cfg.max_bet; end if;
  select * into u from users where id = u.id for update;
  if u.balance < p_stake then raise exception 'No tienes suficientes fichas (% disponibles).', u.balance; end if;
  cresult := case when random() < 0.5 then 'cara' else 'cruz' end;
  won := (cchoice = cresult);
  payout := case when won then floor(p_stake * cfg.mult) else 0 end;
  new_bal := u.balance - p_stake + payout;
  update users set balance = new_bal where id = u.id;
  update coinflip_stats set flips = flips + 1, bets = bets + p_stake, paid = paid + payout where id = 1;
  insert into coinflip_bet (user_id, uname, choice, stake, result, won, payout, created)
  values (u.id, u.name, cchoice, p_stake, cresult, won, payout, p_now);
  date_txt := to_char(now(), 'DD/MM/YYYY HH24:MI:SS');
  insert into ledger (date, uname, type, amount, detail, ts)
  values (date_txt, u.name, 'Cara o Cruz', -p_stake,
          'Lanzaste ' || p_stake || ' fichas a ' || cchoice, p_now);
  if won then
    insert into ledger (date, uname, type, amount, detail, ts)
    values (date_txt, u.name, 'Cara o Cruz - Premio', payout,
            'Cayó ' || cresult || ' · ganaste ' || payout || ' fichas', p_now + 1);
  end if;
  return jsonb_build_object('choice', cchoice, 'result', cresult, 'won', won,
    'stake', p_stake, 'payout', payout, 'balance', new_bal);
end $$;

-- ---------- administración ----------
create or replace function public.coinflip_admin_info(p_token text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  a users; cfg coinflip_config; stats coinflip_stats; recent jsonb;
begin
  a := public._sess_user(p_token);
  if a.id is null or not a.admin then raise exception 'Solo el administrador.'; end if;
  select * into cfg from coinflip_config where id = 1;
  select * into stats from coinflip_stats where id = 1;
  select coalesce(jsonb_agg(jsonb_build_object('id', b.id, 'uname', b.uname, 'user_id', b.user_id,
           'choice', b.choice, 'stake', b.stake, 'result', b.result,
           'won', b.won, 'payout', b.payout, 'created', b.created) order by b.created desc), '[]'::jsonb)
    into recent from (select * from coinflip_bet order by created desc limit 40) b;
  return jsonb_build_object('mult', cfg.mult, 'max_bet', cfg.max_bet,
    'flips', stats.flips, 'bets', stats.bets, 'paid', stats.paid,
    'profit', stats.bets - stats.paid, 'recent', recent);
end $$;

create or replace function public.coinflip_admin_config(p_token text, p_mult numeric, p_max_bet bigint)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare a users; vmult numeric; vmax bigint;
begin
  a := public._sess_user(p_token);
  if a.id is null or not a.admin then raise exception 'Solo el administrador.'; end if;
  vmult := round(greatest(1.01, least(10, coalesce(p_mult, 1.9))), 2);
  vmax := greatest(coalesce(p_max_bet, 1), 1);
  update coinflip_config set mult = vmult, max_bet = vmax where id = 1;
  return jsonb_build_object('mult', vmult, 'max_bet', vmax);
end $$;

grant execute on function public.coinflip_state(text) to anon, authenticated;
grant execute on function public.coinflip_flip(text, text, integer, bigint) to anon, authenticated;
grant execute on function public.coinflip_admin_info(text) to anon, authenticated;
grant execute on function public.coinflip_admin_config(text, numeric, bigint) to anon, authenticated;