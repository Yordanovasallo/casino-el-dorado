-- ============ DOMINÓ (2-4 JUGADORES, CON APUESTAS) ============
-- Juego doble-nueve (55 fichas 0-0 … 9-9). Cada jugador recibe 10 fichas
-- y el resto van al pozo (trago). Al sentarse el 2º la mesa reparte sola
-- tras un breve lobby para que entren hasta 4. Fase de apuesta libre antes
-- de jugar la primera ficha (0 = pasar). La salida la tiene la ficha doble
-- más alta (o la ficha más alta si no hay dobles repartidos) y debe jugarse
-- primero. Turnos: si tienes ficha que calce DEBES jugarla; si no, robas del
-- pozo hasta poder o hasta que se agote; con pozo vacío y sin calce pasas.
-- Gana el primero que vacía su mano; si todos pasan seguido (trancado),
-- gana el de menos puntos y el resto paga la diferencia. El ganador se
-- lleva el 99% del bote (la casa retiene el 1%).

drop function if exists public.dom_state(text);
drop function if exists public.dom_join(text);
drop function if exists public.dom_leave(text);
drop function if exists public.dom_bet(text, int, bigint);
drop function if exists public.dom_play(text, jsonb, text, bigint);
drop function if exists public.dom_draw(text);
drop function if exists public.dom_pass(text);
drop function if exists public.dom_tick(bigint);
drop function if exists public.dom_canplay(jsonb, int, int, jsonb);
drop function if exists public.dom_start_playing(bigint);
drop function if exists public.dom_exec_play(text, jsonb, text, bigint);
drop function if exists public.dom_auto_draw(text);
drop function if exists public.dom_auto_act(bigint);
drop function if exists public.dom_resolve_win(text, bigint);
drop function if exists public.dom_resolve_trancado();
drop function if exists public.dom_deal(bigint);

drop table if exists public.dom;
drop table if exists public.dom_hand;

create table public.dom (
  id int primary key default 1 check (id = 1),
  phase text not null default 'waiting',          -- waiting | betting | playing | done
  players jsonb not null default '[]'::jsonb,     -- [{id,name,bet,acted}]
  pot int not null default 0,
  board jsonb not null default '[]'::jsonb,       -- [{v:[a,b], side:L|R, p, n}]
  leftv int,                                      -- extremo abierto izquierdo
  rightv int,                                     -- extremo abierto derecho
  turn int not null default 0,
  round_end bigint not null default 0,
  passes int not null default 0,                  -- pases seguidos (trancado)
  salida jsonb,                                   -- ficha de salida exigida
  result jsonb
);
alter table public.dom enable row level security;

-- Fichas privadas por jugador y el pozo (id 'pozo')
create table public.dom_hand (
  id text primary key,
  tiles jsonb not null default '[]'::jsonb
);
alter table public.dom_hand enable row level security;

-- ============ Ayuda: ¿puede jugar? (mesa vacía => debe jugar la salida) ============
create or replace function public.dom_canplay(p_hand jsonb, p_left int, p_right int, p_salida jsonb)
returns boolean language sql stable security definer set search_path = public as $$
  select case
    when p_left is null and p_right is null then
      (select p_hand @> jsonb_build_array(p_salida))
    else
      (select coalesce(bool_or(
        (t->>0)::int = p_left or (t->>1)::int = p_left or
        (t->>0)::int = p_right or (t->>1)::int = p_right), false)
       from jsonb_array_elements(p_hand) t)
  end;
$$;

-- ============ ESTADO ============
create or replace function public.dom_state(p_user_id text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare g dom%rowtype; arr jsonb := '[]'::jsonb; p jsonb; h jsonb; pip int;
begin
  select * into g from dom where id = 1;
  for p in select e from jsonb_array_elements(g.players) e loop
    h := coalesce((select tiles from dom_hand where id = p->>'id'), '[]'::jsonb);
    pip := coalesce((select sum((t->>0)::int + (t->>1)::int) from jsonb_array_elements(h) t), 0);
    arr := arr || jsonb_build_object(
      'id', p->>'id', 'name', p->>'name',
      'bet', (p->>'bet')::int, 'acted', (p->>'acted')::boolean,
      'hand_len', jsonb_array_length(h),
      'pips', case when p_user_id is not null and p->>'id' = p_user_id then pip else null end,
      'hand', case when p_user_id is not null and p->>'id' = p_user_id then h else null end
    );
  end loop;
  return jsonb_build_object(
    'phase', g.phase, 'pot', g.pot, 'board', g.board,
    'left', g.leftv, 'right', g.rightv, 'turn', g.turn,
    'round_end', g.round_end, 'passes', g.passes, 'salida', g.salida,
    'pozo', coalesce((select jsonb_array_length(tiles) from dom_hand where id = 'pozo'), 0),
    'players', arr, 'result', g.result
  );
end $$;

-- ============ SENTARSE / LEVANTARSE ============
create or replace function public.dom_join(p_user_id text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare me users; g dom%rowtype; arr jsonb; n int; now_ms bigint;
begin
  now_ms := (extract(epoch from now()) * 1000)::bigint;
  select * into me from users where id = p_user_id;
  if not found then raise exception 'Sesión expirada. Cierra y vuelve a entrar.'; end if;
  if me.admin then raise exception 'La cuenta de administración no puede jugar.'; end if;
  select * into g from dom where id = 1 for update;
  if g.phase in ('betting', 'playing') then raise exception 'La partida ya empezó. Espera a que termine.'; end if;
  arr := g.players;
  if (select count(*) from jsonb_array_elements(arr) e where e->>'id' = p_user_id) > 0 then
    return (select dom_state(p_user_id));
  end if;
  if (select jsonb_array_length(arr)) >= 4 then
    raise exception 'La mesa está llena (máximo 4 jugadores).';
  end if;
  arr := arr || jsonb_build_array(jsonb_build_object('id', me.id, 'name', me.name, 'bet', 0, 'acted', false));
  update dom set players = arr where id = 1;
  -- Lobby: al sentarse el 2º (o más) arma una cuenta de 8 s para que entren hasta 4
  n := (select jsonb_array_length(arr));
  if n >= 2 then
    update dom set round_end = now_ms + 8000 where id = 1;
  end if;
  return (select dom_state(p_user_id));
end $$;

create or replace function public.dom_leave(p_user_id text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare g dom%rowtype; arr jsonb;
begin
  select * into g from dom where id = 1 for update;
  if g.phase in ('betting', 'playing') then raise exception 'No puedes irte a mitad de partida.'; end if;
  arr := coalesce((select jsonb_agg(e) from jsonb_array_elements(g.players) e where e->>'id' <> p_user_id), '[]'::jsonb);
  update dom set players = arr where id = 1;
  delete from dom_hand where id = p_user_id;
  return (select dom_state(p_user_id));
end $$;

-- ============ REPARTIR ============
create or replace function public.dom_deal(p_now bigint)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  g dom%rowtype;
  deck jsonb := '[]'::jsonb;
  n int; i int;
  tiles jsonb; pozo_tiles jsonb;
  arr jsonb := '[]'::jsonb;
  pc record;
begin
  select * into g from dom where id = 1 for update;
  if g.phase in ('betting', 'playing') then raise exception 'Ya hay una partida en juego. Espera a que termine.'; end if;
  n := jsonb_array_length(g.players);
  if n < 2 then raise exception 'Se necesitan al menos 2 jugadores sentados.'; end if;
  if exists(
    select 1 from jsonb_array_elements(g.players) e join users u on u.id = e->>'id'
    where u.balance < 1
  ) then
    raise exception 'No todos los jugadores sentados tienen fichas.';
  end if;
  -- Barajar las 55 fichas del doble-nueve (a >= b)
  select jsonb_agg(jsonb_build_array(x.a, x.b) order by random())
    into deck
    from (select a, b from generate_series(0, 9) a, generate_series(0, a) b) x;
  i := 1;
  for pc in select e->>'id' jid, e->>'name' jname from jsonb_array_elements(g.players) e loop
    tiles := (select jsonb_agg(t) from (select t from jsonb_array_elements(deck) t offset (i - 1) * 10 limit 10) s);
    i := i + 1;
    delete from dom_hand where id = pc.jid;
    insert into dom_hand (id, tiles) values (pc.jid, tiles);
    arr := arr || jsonb_build_object('id', pc.jid, 'name', pc.jname, 'bet', 0, 'acted', false);
  end loop;
  pozo_tiles := (select jsonb_agg(t) from (select t from jsonb_array_elements(deck) t offset n * 10) s);
  delete from dom_hand where id = 'pozo';
  insert into dom_hand (id, tiles) values ('pozo', pozo_tiles);
  update dom set
    phase = 'betting', players = arr, pot = 0, board = '[]'::jsonb,
    leftv = null, rightv = null, turn = 0, round_end = p_now + 45000,
    passes = 0, salida = null, result = null
  where id = 1;
  return (select dom_state());
end $$;

-- ============ APUESTA LIBRE (0 = pasar) ============
create or replace function public.dom_bet(p_user_id text, p_amount int, p_now bigint)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  g dom%rowtype;
  u users;
  arr jsonb;
  idx int;
  all_acted boolean;
begin
  select * into g from dom where id = 1 for update;
  if g.phase <> 'betting' then raise exception 'Las apuestas están cerradas.'; end if;
  if p_now > g.round_end then raise exception 'El tiempo de apuesta se acabó.'; end if;
  select * into u from users where id = p_user_id for update;
  if not found then raise exception 'Sesión expirada.'; end if;
  if p_amount < 0 then raise exception 'Apuesta no válida (0 = pasar).'; end if;
  if u.balance < p_amount then raise exception 'No tienes suficientes fichas.'; end if;
  arr := g.players;
  idx := (select ord - 1 from jsonb_array_elements(arr) with ordinality as x(e, ord) where x.e->>'id' = p_user_id);
  if idx is null then raise exception 'No estás en esta mesa.'; end if;
  if (arr->idx->>'acted')::boolean then raise exception 'Ya actuaste en esta ronda.'; end if;
  if p_amount > 0 then
    update users set balance = balance - p_amount where id = p_user_id;
    arr := jsonb_set(arr, array[idx::text], (arr->idx) || jsonb_build_object('bet', (arr->idx->>'bet')::int + p_amount), true);
    insert into ledger (date, uname, type, amount, detail, ts)
    values (to_char(now(), 'DD/MM/YYYY HH24:MI:SS'), u.name, 'Dominó', -p_amount, 'Apuesta en la mesa', p_now);
  end if;
  arr := jsonb_set(arr, array[idx::text], (arr->idx) || jsonb_build_object('acted', true), true);
  update dom set players = arr, pot = g.pot + p_amount where id = 1;
  all_acted := (select coalesce(bool_and((e->>'acted')::boolean), false) from jsonb_array_elements(arr) e);
  if all_acted then perform public.dom_start_playing(p_now); end if;
  return (select dom_state(p_user_id));
end $$;

-- Salida: la ficha doble más alta; si no hay dobles, la ficha más alta.
create or replace function public.dom_start_playing(p_now bigint)
returns void language plpgsql security definer set search_path = public as $$
declare
  g dom%rowtype;
  h jsonb; t jsonb; a int; b int;
  best_a int; best_b int; bid text; bname text; best_tile jsonb;
  p jsonb; turn_idx int;
begin
  select * into g from dom where id = 1 for update;
  if g.phase <> 'betting' then return; end if;
  best_a := null; best_b := null; bid := null; best_tile := null;
  -- 1er pase: buscar dobles
  for p in select e from jsonb_array_elements(g.players) e loop
    h := coalesce((select tiles from dom_hand where id = p->>'id'), '[]'::jsonb);
    for t in select e2 from jsonb_array_elements(h) e2 loop
      a := (t->>0)::int; b := (t->>1)::int;
      if a = b and (best_a is null or a > best_a) then
        best_a := a; best_b := b; bid := p->>'id'; bname := p->>'name'; best_tile := t;
      end if;
    end loop;
  end loop;
  -- 2º pase: sin dobles, la ficha más alta
  if best_a is null then
    for p in select e from jsonb_array_elements(g.players) e loop
      h := coalesce((select tiles from dom_hand where id = p->>'id'), '[]'::jsonb);
      for t in select e2 from jsonb_array_elements(h) e2 loop
        a := (t->>0)::int; b := (t->>1)::int;
        if best_a is null or (a > best_a) or (a = best_a and b > best_b) then
          best_a := a; best_b := b; bid := p->>'id'; bname := p->>'name'; best_tile := t;
        end if;
      end loop;
    end loop;
  end if;
  if bid is null then raise exception 'No se pudo determinar la salida.'; end if;
  turn_idx := (select ord - 1 from jsonb_array_elements(g.players) with ordinality as x(e, ord) where x.e->>'id' = bid);
  update dom set
    phase = 'playing', turn = turn_idx, round_end = p_now + 45000,
    passes = 0, salida = best_tile, leftv = null, rightv = null, board = '[]'::jsonb
  where id = 1;
end $$;

-- ============ JUGAR FICHA ============
-- Ejecuta el tiro real (sin validar turno/tiempo). Valida que la ficha esté
-- en la mano, que calce en el extremo elegido y la regla de salida.
create or replace function public.dom_exec_play(p_user_id text, p_tile jsonb, p_side text, p_now bigint)
returns void language plpgsql security definer set search_path = public as $$
declare
  g dom%rowtype;
  u users;
  hand jsonb;
  x int; y int; a int; b int; canon jsonb;
  new_l int; new_r int; posn text; n int;
begin
  select * into g from dom where id = 1 for update;
  select * into u from users where id = p_user_id;
  x := (p_tile->>0)::int; y := (p_tile->>1)::int;
  a := greatest(x, y); b := least(x, y); canon := jsonb_build_array(a, b);
  hand := (select tiles from dom_hand where id = p_user_id);
  if not (hand @> jsonb_build_array(canon)) then
    raise exception 'No tienes esa ficha.';
  end if;
  if g.leftv is null and g.rightv is null then
    if canon <> g.salida then
      raise exception 'La salida debe ser la ficha %-% y la juega su dueño.', (g.salida->>0)::int, (g.salida->>1)::int;
    end if;
    new_l := a; new_r := b; posn := p_side;
  elsif p_side = 'R' then
    if a = g.rightv or b = g.rightv then
      new_r := case when a = g.rightv then b else a end;
      posn := 'R';
    else
      raise exception 'Esa ficha no va por el extremo derecho.';
    end if;
  else
    if a = g.leftv or b = g.leftv then
      new_l := case when a = g.leftv then b else a end;
      posn := 'L';
    else
      raise exception 'Esa ficha no va por el extremo izquierdo.';
    end if;
  end if;
  -- Quitar la ficha de la mano
  update dom_hand
    set tiles = coalesce((select jsonb_agg(t) from jsonb_array_elements(hand) t where not (t = canon)), '[]'::jsonb)
    where id = p_user_id;
  -- ¿Ganó al vaciar la mano?
  if (select jsonb_array_length(tiles) from dom_hand where id = p_user_id) = 0 then
    perform public.dom_resolve_win(p_user_id, p_now);
    return;
  end if;
  n := (select jsonb_array_length(g.players));
  update dom set
    board = g.board || jsonb_build_array(jsonb_build_object('v', canon, 'side', posn, 'p', p_user_id, 'n', u.name)),
    leftv = coalesce(new_l, g.leftv),
    rightv = coalesce(new_r, g.rightv),
    passes = 0,
    turn = (g.turn + 1) % n,
    round_end = p_now + 45000
  where id = 1;
end $$;

create or replace function public.dom_play(p_user_id text, p_tile jsonb, p_side text, p_now bigint)
returns jsonb language plpgsql security definer set search_path = public as $$
declare g dom%rowtype;
begin
  select * into g from dom where id = 1 for update;
  if g.phase <> 'playing' then raise exception 'La mano no está en juego.'; end if;
  if (select (g.players->g.turn->>'id')) <> p_user_id then raise exception 'No es tu turno.'; end if;
  if p_now > g.round_end then raise exception 'Se acabó tu tiempo. La mesa resolverá tu turno.'; end if;
  perform public.dom_exec_play(p_user_id, p_tile, p_side, p_now);
  return (select dom_state(p_user_id));
end $$;

-- ============ ROBAR DEL POZO (solo si no tienes ficha para jugar) ============
create or replace function public.dom_draw(p_user_id text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  g dom%rowtype;
  hand jsonb; pozo jsonb; c jsonb;
begin
  select * into g from dom where id = 1 for update;
  if g.phase <> 'playing' then raise exception 'La mano no está en juego.'; end if;
  if (select (g.players->g.turn->>'id')) <> p_user_id then raise exception 'No es tu turno.'; end if;
  pozo := (select tiles from dom_hand where id = 'pozo');
  if jsonb_array_length(pozo) = 0 then raise exception 'El pozo ya está vacío.'; end if;
  hand := (select tiles from dom_hand where id = p_user_id);
  if dom_canplay(hand, g.leftv, g.rightv, g.salida) then raise exception 'Tienes fichas que calzan; debes jugar.'; end if;
  c := pozo->0;
  update dom_hand
    set tiles = coalesce((select jsonb_agg(t) from jsonb_array_elements(pozo) t where not (t = c)), '[]'::jsonb)
    where id = 'pozo';
  update dom_hand
    set tiles = (select tiles from dom_hand where id = p_user_id) || jsonb_build_array(c)
    where id = p_user_id;
  return (select dom_state(p_user_id));
end $$;

-- ============ PASAR (solo sin fichas que calcen Y con pozo vacío) ============
create or replace function public.dom_pass(p_user_id text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare g dom%rowtype; n int; now_ms bigint;
begin
  now_ms := (extract(epoch from now()) * 1000)::bigint;
  select * into g from dom where id = 1 for update;
  if g.phase <> 'playing' then raise exception 'La mano no está en juego.'; end if;
  if (select (g.players->g.turn->>'id')) <> p_user_id then raise exception 'No es tu turno.'; end if;
  if dom_canplay((select tiles from dom_hand where id = p_user_id), g.leftv, g.rightv, g.salida) then
    raise exception 'Tienes fichas que calzan; debes jugar.';
  end if;
  if (select jsonb_array_length(tiles) from dom_hand where id = 'pozo') > 0 then
    raise exception 'El pozo todavía tiene fichas; debes robar.';
  end if;
  n := (select jsonb_array_length(g.players));
  if g.passes + 1 >= n then
    perform public.dom_resolve_trancado();
  else
    update dom set
      passes = g.passes + 1,
      turn = (g.turn + 1) % n,
      round_end = now_ms + 45000
    where id = 1;
  end if;
  return (select dom_state(p_user_id));
end $$;

-- ============ RESOLUCIÓN ============
-- Manos finales para el resultado
create or replace function public.dom_result_hands()
returns jsonb language plpgsql security definer set search_path = public as $$
declare g dom%rowtype; p jsonb; h jsonb; hands jsonb := '[]'::jsonb; pip int;
begin
  select * into g from dom where id = 1;
  for p in select e from jsonb_array_elements(g.players) e loop
    h := coalesce((select tiles from dom_hand where id = p->>'id'), '[]'::jsonb);
    pip := coalesce((select sum((t->>0)::int + (t->>1)::int) from jsonb_array_elements(h) t), 0);
    hands := hands || jsonb_build_object('id', p->>'id', 'name', p->>'name', 'tiles', h, 'pips', pip);
  end loop;
  return hands;
end $$;

-- Ganó el que vació su mano
create or replace function public.dom_resolve_win(p_winner text, p_now bigint)
returns void language plpgsql security definer set search_path = public as $$
declare g dom%rowtype; prize int; wname text;
begin
  select * into g from dom where id = 1 for update;
  prize := floor(g.pot * 0.99);
  wname := (select e->>'name' from jsonb_array_elements(g.players) e where e->>'id' = p_winner limit 1);
  if wname is null then wname := p_winner; end if;
  update users set balance = balance + prize where id = p_winner;
  insert into ledger (date, uname, type, amount, detail, ts)
  values (to_char(now(), 'DD/MM/YYYY HH24:MI:SS'), wname, 'Dominó - Premio', prize,
          'Jugó su última ficha. Casa retiene 1% del bote.', p_now);
  update dom set phase = 'done', round_end = p_now + 12000,
    result = jsonb_build_object('winner', p_winner, 'name', wname, 'prize', prize,
                                'kind', 'win', 'hands', dom_result_hands())
  where id = 1;
end $$;

-- Trancado: gana el de menos puntos y el resto paga la diferencia
create or replace function public.dom_resolve_trancado()
returns void language plpgsql security definer set search_path = public as $$
declare
  g dom%rowtype;
  p jsonb; h jsonb; pip int;
  min_pip int; wids text := ''; wn int := 0; any_winner text := null; wname text := '';
  prize int; base int; diff int; pay int;
  u users; winner_bal int;
  loser_bal int; winner_row users%rowtype;
  hands jsonb; now_ms bigint;
  parts text[];
begin
  now_ms := (extract(epoch from now()) * 1000)::bigint;
  select * into g from dom where id = 1 for update;
  -- pips por jugador
  min_pip := null;
  hands := dom_result_hands();
  for p in select e from jsonb_array_elements(g.players) e loop
    h := coalesce((select tiles from dom_hand where id = p->>'id'), '[]'::jsonb);
    pip := coalesce((select sum((t->>0)::int + (t->>1)::int) from jsonb_array_elements(h) t), 0);
    if min_pip is null or pip < min_pip then min_pip := pip; end if;
  end loop;
  -- ganadores (empatados en el mínimo)
  for p in select e from jsonb_array_elements(hands) e loop
    if (p->>'pips')::int = min_pip then
      wn := wn + 1;
      if any_winner is null then any_winner := p->>'id'; wname := p->>'name'; end if;
    end if;
  end loop;
  prize := floor(g.pot * 0.99);
  if wn = 1 then
    -- el resto paga la diferencia al ganador
    update users set balance = balance + prize where id = any_winner;
    insert into ledger (date, uname, type, amount, detail, ts)
    values (to_char(now(), 'DD/MM/YYYY HH24:MI:SS'), wname, 'Dominó - Premio', prize,
            'Trancado: menos puntos. Casa retiene 1% del bote.', now_ms);
    for p in select e from jsonb_array_elements(hands) e loop
      if p->>'id' = any_winner then continue; end if;
      diff := (p->>'pips')::int - min_pip;
      if diff > 0 then
        select balance into loser_bal from users where id = p->>'id';
        pay := least(diff, loser_bal);
        if pay > 0 then
          update users set balance = balance - pay where id = p->>'id';
          update users set balance = balance + pay where id = any_winner;
          insert into ledger (date, uname, type, amount, detail, ts)
          values (to_char(now(), 'DD/MM/YYYY HH24:MI:SS'), p->>'name', 'Dominó - Diferencia', -pay,
                  'Paga la diferencia en puntos (trancado).', now_ms);
          insert into ledger (date, uname, type, amount, detail, ts)
          values (to_char(now(), 'DD/MM/YYYY HH24:MI:SS'), wname, 'Dominó - Diferencia', pay,
                  'Cobra la diferencia del trancado.', now_ms + 1);
        end if;
      end if;
    end loop;
    update dom set phase = 'done', round_end = now_ms + 12000,
      result = jsonb_build_object('winner', any_winner, 'name', wname, 'prize', prize,
                                  'kind', 'trancado', 'min_pips', min_pip, 'hands', hands)
    where id = 1;
  else
    -- empate en el mínimo: se reparte el 99% entre ellos, sin diferencias
    base := floor(prize / wn);
    for p in select e from jsonb_array_elements(hands) e loop
      if (p->>'pips')::int = min_pip then
        update users set balance = balance + base where id = p->>'id';
        insert into ledger (date, uname, type, amount, detail, ts)
        values (to_char(now(), 'DD/MM/YYYY HH24:MI:SS'), p->>'name', 'Dominó - Premio', base,
                'Trancado empatado en puntos. Casa retiene 1% del bote.', now_ms);
      end if;
    end loop;
    update dom set phase = 'done', round_end = now_ms + 12000,
      result = jsonb_build_object('winner', any_winner, 'name', wname, 'prize', base,
                                  'kind', 'trancado', 'min_pips', min_pip, 'hands', hands)
    where id = 1;
  end if;
end $$;

-- ============ TICK (auto jugar, auto repartir) ============
-- Acción automática para el jugador al que se le agotó el tiempo de turno.
create or replace function public.dom_auto_draw(p_user_id text)
returns void language plpgsql security definer set search_path = public as $$
declare pozo jsonb; c jsonb;
begin
  pozo := (select tiles from dom_hand where id = 'pozo');
  if jsonb_array_length(pozo) = 0 then return; end if;
  c := pozo->0;
  update dom_hand
    set tiles = coalesce((select jsonb_agg(t) from jsonb_array_elements(pozo) t where not (t = c)), '[]'::jsonb)
    where id = 'pozo';
  update dom_hand
    set tiles = (select tiles from dom_hand where id = p_user_id) || jsonb_build_array(c)
    where id = p_user_id;
end $$;

create or replace function public.dom_auto_act(p_now bigint)
returns void language plpgsql security definer set search_path = public as $$
declare
  g dom%rowtype;
  cur text; hand jsonb; t jsonb; chosen jsonb; side text;
  a int; b int; n int; now_ms bigint;
begin
  now_ms := (extract(epoch from now()) * 1000)::bigint;
  select * into g from dom where id = 1 for update;
  if g.phase <> 'playing' then return; end if;
  cur := g.players->g.turn->>'id';
  n := (select jsonb_array_length(g.players));
  loop
    hand := (select tiles from dom_hand where id = cur);
    if dom_canplay(hand, g.leftv, g.rightv, g.salida) then
      exit;
    end if;
    if (select jsonb_array_length(tiles) from dom_hand where id = 'pozo') > 0 then
      perform public.dom_auto_draw(cur);
      continue;
    end if;
    -- pasar
    if g.passes + 1 >= n then
      perform public.dom_resolve_trancado();
      return;
    end if;
    update dom set
      passes = g.passes + 1,
      turn = (g.turn + 1) % n,
      round_end = now_ms + 45000
    where id = 1;
    return;
  end loop;
  -- jugar la ficha más ligera de las que calzan
  if g.leftv is null and g.rightv is null then
    chosen := g.salida; side := 'L';
  else
    select t2 into chosen
      from jsonb_array_elements(hand) t2
      where (t2->>0)::int = g.leftv or (t2->>1)::int = g.leftv or
            (t2->>0)::int = g.rightv or (t2->>1)::int = g.rightv
      order by ((t2->>0)::int + (t2->>1)::int) asc, (t2->>0)::int asc
      limit 1;
    a := (chosen->>0)::int; b := (chosen->>1)::int;
    side := case when a = g.leftv or b = g.leftv then 'L' else 'R' end;
  end if;
  perform public.dom_exec_play(cur, chosen, side, p_now);
end $$;

create or replace function public.dom_tick(p_now bigint)
returns jsonb language plpgsql security definer set search_path = public as $$
declare g dom%rowtype; arr jsonb;
begin
  select * into g from dom where id = 1 for update;
  if g.phase = 'betting' then
    if p_now > g.round_end then
      arr := (select jsonb_agg(
                case when (e->>'acted')::boolean then e else e || jsonb_build_object('acted', true, 'bet', 0) end
              ) from jsonb_array_elements(g.players) e);
      update dom set players = arr where id = 1;
      perform public.dom_start_playing(p_now);
    end if;
  elsif g.phase = 'playing' then
    if p_now > g.round_end then
      perform public.dom_auto_act(p_now);
    end if;
  end if;
  select * into g from dom where id = 1;
  if g.phase not in ('betting', 'playing')
     and (select jsonb_array_length(g.players)) >= 2
     and (select coalesce(bool_and(u.balance >= 1), false)
          from jsonb_array_elements(g.players) e join users u on u.id = e->>'id')
     and p_now >= g.round_end
  then
    perform public.dom_deal(p_now);
  end if;
  return (select dom_state());
end $$;

-- ============ ACCESOS ============
grant execute on function public.dom_state(text) to anon, authenticated;
grant execute on function public.dom_join(text) to anon, authenticated;
grant execute on function public.dom_leave(text) to anon, authenticated;
grant execute on function public.dom_bet(text, int, bigint) to anon, authenticated;
grant execute on function public.dom_play(text, jsonb, text, bigint) to anon, authenticated;
grant execute on function public.dom_draw(text) to anon, authenticated;
grant execute on function public.dom_pass(text) to anon, authenticated;
grant execute on function public.dom_tick(bigint) to anon, authenticated;

insert into public.dom (id) values (1) on conflict do nothing;