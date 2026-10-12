-- ============================================================
-- APUESTAS DEPORTIVAS (The Odds API) — gratis y automáticas
-- 1X2 (gana local / empate / gana visita) antes del partido.
-- Usa el saldo de fichas del casino (users.balance + ledger).
-- ============================================================

drop function if exists public.bets_admin_setup(text, text, jsonb);
drop function if exists public.bets_refresh_all();
drop function if exists public.bets_settle_all();
drop function if exists public.bets_refresh(text);
drop function if exists public.bets_settle_sport(text);
drop function if exists public.bets_settle(text, text, text, bigint);
drop function if exists public.bets_settle(text, text, bigint);
drop function if exists public.bets_void(text, text, bigint);
drop function if exists public.bets_void(text, bigint);
drop function if exists public._bet_settle_apply(text, text, bigint);
drop function if exists public._bet_void_apply(text, bigint);
drop function if exists public.bets_place(text, text, text, int, bigint);
drop function if exists public.bets_list(text);
drop table if exists public.bets;
drop table if exists public.bet_event;
drop table if exists public.bet_config;

create table public.bet_config (
  id int primary key default 1 check (id = 1),
  api_key text default '',
  sports jsonb not null default '["soccer_epl","soccer_spain_la_liga","basketball_nba"]'::jsonb,
  region text not null default 'eu',
  updated bigint not null default 0
);
alter table public.bet_config enable row level security;

create table public.bet_event (
  id text primary key,
  sport_key text not null,
  sport_title text,
  home text not null,
  away text not null,
  commence_time timestamptz not null,
  odds_home numeric,
  odds_draw numeric,
  odds_away numeric,
  status text not null default 'open',   -- open | settled | void
  result text,                           -- home | draw | away
  updated bigint not null default 0
);
alter table public.bet_event enable row level security;

create table public.bets (
  id bigserial primary key,
  user_id text not null,
  event_id text not null,
  pick text not null,          -- home | draw | away
  pick_name text,
  stake int not null,
  odds numeric not null,
  status text not null default 'open',  -- open | won | lost | void
  payout int not null default 0,
  created bigint not null
);
alter table public.bets enable row level security;

-- ============ TRAER CUOTAS ============
create or replace function public.bets_refresh(p_sport text)
returns int language plpgsql security definer set search_path = public, extensions as $$
declare
  v_key text; v_url text; v_status int; v_content text;
  evs jsonb; ev jsonb; bm jsonb; mk jsonb; oc jsonb;
  v_home text; v_away text; v_ct timestamptz;
  oh numeric; od numeric; oa numeric; v_nm text; v_pr numeric; cnt int := 0;
begin
  select api_key into v_key from bet_config where id = 1;
  if v_key is null or v_key = '' then raise exception 'Falta la clave de la API.'; end if;
  v_url := 'https://api.the-odds-api.com/v4/sports/' || p_sport ||
           '/odds/?apiKey=' || v_key || '&regions=eu&markets=h2h&oddsFormat=decimal';
  select status, content into v_status, v_content from http_get(v_url);
  if v_status <> 200 then raise exception 'La API respondió %', v_status; end if;
  evs := v_content::jsonb;
  for ev in select e from jsonb_array_elements(evs) e loop
    v_home := ev->>'home_team'; v_away := ev->>'away_team';
    v_ct := (ev->>'commence_time')::timestamptz;
    oh := null; od := null; oa := null;
    for bm in select b from jsonb_array_elements(ev->'bookmakers') b loop
      for mk in select m from jsonb_array_elements(bm->'markets') m where m->>'key' = 'h2h' loop
        for oc in select o from jsonb_array_elements(mk->'outcomes') o loop
          v_nm := oc->>'name'; v_pr := (oc->>'price')::numeric;
          if v_nm = v_home then oh := greatest(coalesce(oh, 0), v_pr);
          elsif v_nm = v_away then oa := greatest(coalesce(oa, 0), v_pr);
          elsif lower(v_nm) = 'draw' then od := greatest(coalesce(od, 0), v_pr);
          end if;
        end loop;
      end loop;
    end loop;
    if oh is not null and oa is not null then
      insert into bet_event (id, sport_key, sport_title, home, away, commence_time,
                             odds_home, odds_draw, odds_away, status, updated)
      values (ev->>'id', ev->>'sport_key', ev->>'sport_title', v_home, v_away, v_ct,
              oh, od, oa, 'open', (extract(epoch from now()) * 1000)::bigint)
      on conflict (id) do update
        set odds_home = excluded.odds_home, odds_draw = excluded.odds_draw, odds_away = excluded.odds_away,
            home = excluded.home, away = excluded.away, commence_time = excluded.commence_time,
            updated = excluded.updated
        where bet_event.status = 'open';
      cnt := cnt + 1;
    end if;
  end loop;
  update bet_config set updated = (extract(epoch from now()) * 1000)::bigint where id = 1;
  return cnt;
end $$;

create or replace function public.bets_refresh_all()
returns jsonb language plpgsql security definer set search_path = public as $$
declare sp text; total int := 0; n int; res jsonb := '{}'::jsonb;
begin
  for sp in select jsonb_array_elements_text(sports) from bet_config where id = 1 loop
    begin
      n := public.bets_refresh(sp);
      total := total + n;
      res := res || jsonb_build_object(sp, n);
    exception when others then
      res := res || jsonb_build_object(sp, 'error: ' || sqlerrm);
    end;
  end loop;
  return jsonb_build_object('total', total, 'detail', res);
end $$;

-- ============ LIQUIDAR (resultados) ============
create or replace function public._bet_settle_apply(p_event text, p_result text, p_now bigint)
returns int language plpgsql security definer set search_path = public as $$
declare ev bet_event; b bets; u users; v_pay int; cnt int := 0; date_txt text;
begin
  if p_result not in ('home', 'draw', 'away') then raise exception 'Resultado no válido.'; end if;
  select * into ev from bet_event where id = p_event for update;
  if not found then raise exception 'No existe ese partido.'; end if;
  if ev.status <> 'open' then return 0; end if;
  update bet_event set status = 'settled', result = p_result, updated = p_now where id = p_event;
  date_txt := to_char(now(), 'DD/MM/YYYY HH24:MI:SS');
  for b in select * from bets where event_id = p_event and status = 'open' for update loop
    if b.pick = p_result then
      v_pay := floor(b.stake * b.odds);
      update bets set status = 'won', payout = v_pay where id = b.id;
      update users set balance = balance + v_pay where id = b.user_id;
      select * into u from users where id = b.user_id;
      insert into ledger (date, uname, type, amount, detail, ts)
      values (date_txt, coalesce(u.name, b.user_id), 'Premio apuesta', v_pay,
              'Acertó ' || ev.home || ' vs ' || ev.away || ' (' || b.pick_name || ') x' || b.odds, p_now);
    else
      update bets set status = 'lost' where id = b.id;
    end if;
    cnt := cnt + 1;
  end loop;
  return cnt;
end $$;

create or replace function public.bets_settle(p_admin text, p_event text, p_result text, p_now bigint)
returns int language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from users where id = p_admin and admin) then
    raise exception 'Solo el administrador puede liquidar partidos.'; end if;
  return public._bet_settle_apply(p_event, p_result, p_now);
end $$;

create or replace function public.bets_settle_sport(p_sport text)
returns int language plpgsql security definer set search_path = public, extensions as $$
declare
  v_key text; v_url text; v_status int; v_content text;
  evs jsonb; ev jsonb; scs jsonb; sc jsonb; res text;
  v_home int; v_away int; v_nm text; v_sc int; cnt int := 0; v_id text;
begin
  select api_key into v_key from bet_config where id = 1;
  if v_key is null or v_key = '' then return 0; end if;
  v_url := 'https://api.the-odds-api.com/v4/sports/' || p_sport ||
           '/scores/?apiKey=' || v_key || '&daysFrom=3';
  select status, content into v_status, v_content from http_get(v_url);
  if v_status <> 200 then raise exception 'La API respondió %', v_status; end if;
  evs := v_content::jsonb;
  for ev in select e from jsonb_array_elements(evs) e loop
    v_id := ev->>'id';
    if (ev->>'completed')::boolean is not true then continue; end if;
    scs := ev->'scores';
    if scs is null or jsonb_typeof(scs) <> 'array' then continue; end if;
    v_home := null; v_away := null;
    for sc in select s from jsonb_array_elements(scs) s loop
      v_nm := sc->>'name';
      begin v_sc := (sc->>'score')::int; exception when others then v_sc := null; end;
      if v_sc is null then continue; end if;
      if v_nm = (ev->>'home_team') then v_home := v_sc;
      elsif v_nm = (ev->>'away_team') then v_away := v_sc; end if;
    end loop;
    if v_home is null or v_away is null then continue; end if;
    res := case when v_home > v_away then 'home' when v_away > v_home then 'away' else 'draw' end;
    if exists (select 1 from bet_event where id = v_id and status = 'open') then
      cnt := cnt + public._bet_settle_apply(v_id, res, (extract(epoch from now()) * 1000)::bigint);
    end if;
  end loop;
  return cnt;
end $$;

create or replace function public.bets_settle_all()
returns jsonb language plpgsql security definer set search_path = public as $$
declare sp text; res jsonb := '{}'::jsonb; n int; total int := 0;
begin
  for sp in select jsonb_array_elements_text(sports) from bet_config where id = 1 loop
    begin
      n := public.bets_settle_sport(sp);
      total := total + n;
      res := res || jsonb_build_object(sp, n);
    exception when others then
      res := res || jsonb_build_object(sp, 'error: ' || sqlerrm);
    end;
  end loop;
  return jsonb_build_object('total', total, 'detail', res);
end $$;

create or replace function public._bet_void_apply(p_event text, p_now bigint)
returns int language plpgsql security definer set search_path = public as $$
declare ev bet_event; b bets; u users; cnt int := 0; date_txt text;
begin
  select * into ev from bet_event where id = p_event for update;
  if not found then raise exception 'No existe ese partido.'; end if;
  update bet_event set status = 'void', updated = p_now where id = p_event;
  date_txt := to_char(now(), 'DD/MM/YYYY HH24:MI:SS');
  for b in select * from bets where event_id = p_event and status = 'open' for update loop
    update bets set status = 'void', payout = b.stake where id = b.id;
    update users set balance = balance + b.stake where id = b.user_id;
    select * into u from users where id = b.user_id;
    insert into ledger (date, uname, type, amount, detail, ts)
    values (date_txt, coalesce(u.name, b.user_id), 'Apuesta anulada', b.stake,
            'Reembolso: ' || ev.home || ' vs ' || ev.away, p_now);
    cnt := cnt + 1;
  end loop;
  return cnt;
end $$;

create or replace function public.bets_void(p_admin text, p_event text, p_now bigint)
returns int language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from users where id = p_admin and admin) then
    raise exception 'Solo el administrador puede anular partidos.'; end if;
  return public._bet_void_apply(p_event, p_now);
end $$;

-- ============ APOSTAR ============
create or replace function public.bets_place(p_user_id text, p_event text, p_pick text, p_stake int, p_now bigint)
returns jsonb language plpgsql security definer set search_path = public as $$
declare u users; ev bet_event; v_odds numeric; v_pickname text; date_txt text;
begin
  select * into u from users where id = p_user_id for update;
  if not found then raise exception 'Sesión expirada. Cierra y vuelve a entrar.'; end if;
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

  update users set balance = balance - p_stake where id = p_user_id;
  insert into bets (user_id, event_id, pick, pick_name, stake, odds, status, created)
  values (p_user_id, p_event, p_pick, v_pickname, p_stake, v_odds, 'open', p_now);
  date_txt := to_char(now(), 'DD/MM/YYYY HH24:MI:SS');
  insert into ledger (date, uname, type, amount, detail, ts)
  values (date_txt, u.name, 'Apuesta', -p_stake,
          ev.home || ' vs ' || ev.away || ' — ' || v_pickname || ' x' || v_odds, p_now);

  return public.bets_list(p_user_id);
end $$;

-- ============ LISTAR ============
create or replace function public.bets_list(p_user_id text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_bal int; v_upd bigint; evs jsonb; mine jsonb;
begin
  select balance into v_bal from users where id = p_user_id;
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
                 from bets b where b.event_id = e.id and b.user_id = p_user_id
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
    where b.user_id = p_user_id
  ) t;
  return jsonb_build_object('balance', v_bal, 'updated', v_upd, 'events', evs, 'mine', mine);
end $$;

-- ============ ADMIN: configurar clave y deportes ============
create or replace function public.bets_admin_setup(p_admin text, p_key text, p_sports jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from users where id = p_admin and admin) then
    raise exception 'Solo el administrador.'; end if;
  if p_key is not null and p_key <> '' then
    update bet_config set api_key = p_key where id = 1;
  end if;
  if p_sports is not null and jsonb_typeof(p_sports) = 'array' then
    update bet_config set sports = p_sports where id = 1;
  end if;
  return (select jsonb_build_object('sports', sports, 'updated', updated) from bet_config where id = 1);
end $$;

insert into public.bet_config (id) values (1) on conflict (id) do nothing;
update public.bet_config set api_key = '7c97cc4206b04c3ae3a4ee55a2d9cf28' where id = 1 and (api_key is null or api_key = '');

grant execute on function public.bets_list(text) to anon, authenticated;
grant execute on function public.bets_place(text, text, text, int, bigint) to anon, authenticated;
grant execute on function public.bets_refresh(text) to anon, authenticated;
grant execute on function public.bets_refresh_all() to anon, authenticated;
grant execute on function public.bets_settle(text, text, text, bigint) to anon, authenticated;
grant execute on function public.bets_settle_sport(text) to anon, authenticated;
grant execute on function public.bets_settle_all() to anon, authenticated;
grant execute on function public.bets_void(text, text, bigint) to anon, authenticated;
grant execute on function public.bets_admin_setup(text, text, jsonb) to anon, authenticated;

-- Los helpers internos NO deben ser accesibles desde la API
revoke all on function public._bet_settle_apply(text, text, bigint) from public, anon, authenticated;
revoke all on function public._bet_void_apply(text, bigint) from public, anon, authenticated;