-- ============================================================
-- Cara o Cruz -> protección de la casa (rentabilidad 5% garantizada)
-- La moneda sigue siendo aleatoria 50/50 mientras la casa esté
-- por encima del 5% de lo recogido. Si dejar ganar al jugador
-- bajaría la casa por debajo de ese 5%, la moneda cae en contra.
-- Resultado: la casa no entra en pérdidas y se recupera sola.
-- ============================================================

create or replace function public.coinflip_flip(p_token text, p_choice text, p_stake integer, p_now bigint)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  u users; cfg coinflip_config; stats coinflip_stats;
  cchoice text; cresult text; won boolean; payout int; new_bal bigint; date_txt text;
  worth bigint; target bigint; profit_win bigint;
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
  select * into stats from coinflip_stats where id = 1;
  -- piso de la casa: 5% de todo lo apostado hasta hoy (incluyendo esta apuesta)
  worth := stats.bets + p_stake;
  target := ceil(worth * 0.05)::bigint;
  -- lo que quedaría a la casa si el jugador gana
  profit_win := ((stats.bets - stats.paid) + p_stake - floor(p_stake * cfg.mult))::bigint;
  if profit_win < target then
    won := false;
    cresult := case when cchoice = 'cara' then 'cruz' else 'cara' end;
  else
    cresult := case when random() < 0.5 then 'cara' else 'cruz' end;
    won := (cchoice = cresult);
  end if;
  payout := case when won then floor(p_stake * cfg.mult)::int else 0 end;
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