-- ============ TRÍO Y PAR (MULTIJUGADOR REAL) ============
-- Mesa compartida: 2-5 jugadores reales, cartas privadas por jugador,
-- rondas de apuesta simultáneas con tiempo límite, bote 99% para el
-- ganador (la casa retiene el 1%). Jerarquía (5 cartas: 3 + 2 mesa):
-- carta alta < par < dos pares < trío < trío y par.

create table if not exists public.trio (
  id int primary key default 1 check (id = 1),
  phase text not null default 'waiting',           -- waiting | betting | done
  players jsonb not null default '[]'::jsonb,      -- [{id,name,ante,bet,folded,acted}]
  pot int not null default 0,
  board jsonb not null default '[]'::jsonb,        -- cartas comunitarias reveladas
  round int not null default 0,                    -- ronda de apuestas actual (1..3)
  reveal_until int not null default 0,             -- nº de comunitarias visibles
  round_end bigint not null default 0,
  dealer int not null default 0,
  result jsonb
);

-- Cartas por jugador ('board' guarda las comunitarias).
-- RLS activado SIN políticas: nadie (anon) puede leerlas vía REST;
-- solo las funciones security definer (owner=postgres) las leen.
create table if not exists public.trio_card (
  id text primary key,
  cards jsonb not null default '[]'::jsonb
);
alter table public.trio_card enable row level security;

-- ============ EVALUACIÓN DE MANOS ============
-- Cartas: 0..51. valor = c % 13 (0=2 … 9,10,11=J,12=Q…12=A), palo = c / 13.
create or replace function public.trio_score(p_cards jsonb)
returns text language sql stable as $$
  with r as (
    select (c::int % 13) rr from jsonb_array_elements_text(p_cards) c
  ),
  g as (
    select rr, count(*) n from r group by rr
  )
  select case
    when exists(select 1 from g where n = 3) and (select count(*) from g where n = 2) = 1 then
      '4' || lpad((select rr::text from g where n = 3), 2, '0') || lpad((select rr::text from g where n = 2), 2, '0')
    when exists(select 1 from g where n = 3) then
      '3' || lpad((select rr::text from g where n = 3), 2, '0')
        || (select string_agg(lpad(rr::text, 2, '0'), '') from (select rr from g where n <> 3 order by rr desc) t)
    when (select count(*) from g where n = 2) = 2 then
      '2' || (select string_agg(lpad(rr::text, 2, '0'), '') from (select rr from g where n = 2 order by rr desc) t)
        || (select string_agg(lpad(rr::text, 2, '0'), '') from (select rr from g where n = 1) t)
    when (select count(*) from g where n = 2) = 1 then
      '1' || lpad((select rr::text from g where n = 2), 2, '0')
        || (select string_agg(lpad(rr::text, 2, '0'), '') from (select rr from g where n <> 2 order by rr desc) t)
    else
      '0' || (select string_agg(lpad(rr::text, 2, '0'), '') from (select rr from r order by rr desc) t)
  end;
$$;

create or replace function public.trio_rankname(p_score text)
returns text language sql immutable as $$
  select case
    when left(p_score, 1) = '4' then 'TRÍO Y PAR'
    when left(p_score, 1) = '3' then 'TRÍO'
    when left(p_score, 1) = '2' then 'DOS PARES'
    when left(p_score, 1) = '1' then 'PAR'
    else 'CARTA ALTA' end;
$$;

-- ============ FUNCIONES RPC ============

create or replace function public.trio_state()
returns jsonb language sql security definer set search_path = public as $$
  select jsonb_build_object(
    'phase', g.phase, 'pot', g.pot, 'board', g.board, 'round', g.round,
    'reveal_until', g.reveal_until, 'round_end', g.round_end, 'dealer', g.dealer,
    'players', g.players, 'result', g.result
  ) from trio g where id = 1;
$$;

create or replace function public.trio_join(p_user_id text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare me users; g trio%rowtype; arr jsonb;
begin
  select * into me from users where id = p_user_id;
  if not found then raise exception 'Sesión expirada. Cierra y vuelve a entrar.'; end if;
  if me.admin then raise exception 'La cuenta de administración no puede jugar.'; end if;
  select * into g from trio where id = 1 for update;
  if g.phase = 'betting' then raise exception 'La mano ya empezó. Espera a que termine.'; end if;
  arr := g.players;
  if (select count(*) from jsonb_array_elements(arr) e where e->>'id' = p_user_id) > 0 then
    return (select trio_state());
  end if;
  if (select jsonb_array_length(arr)) >= 5 then
    raise exception 'La mesa está llena (máximo 5 jugadores).';
  end if;
  arr := arr || jsonb_build_array(jsonb_build_object('id', me.id, 'name', me.name, 'ante', 0, 'bet', 0, 'folded', false, 'acted', false));
  update trio set players = arr where id = 1;
  return (select trio_state());
end $$;

create or replace function public.trio_leave(p_user_id text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare g trio%rowtype; arr jsonb;
begin
  select * into g from trio where id = 1 for update;
  if g.phase = 'betting' then raise exception 'No puedes irte a mitad de mano.'; end if;
  arr := coalesce((select jsonb_agg(e) from jsonb_array_elements(g.players) e where e->>'id' <> p_user_id), '[]'::jsonb);
  update trio set players = arr where id = 1;
  return (select trio_state());
end $$;

create or replace function public.trio_deal(p_now bigint)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  g trio%rowtype;
  deck int[];
  i int; n int;
  mine int[];
  arr jsonb := '[]'::jsonb;
  pc record;
  board int[];
begin
  select * into g from trio where id = 1 for update;
  if g.phase = 'betting' then raise exception 'Ya hay una mano en juego. Espera a que termine.'; end if;
  n := jsonb_array_length(g.players);
  if n < 2 then raise exception 'Se necesitan al menos 2 jugadores sentados para repartir.'; end if;
  if exists(
    select 1 from jsonb_array_elements(g.players) e join users u on u.id = e->>'id'
    where u.balance < 10
  ) then
    raise exception 'No todos los jugadores sentados tienen 10 fichas para la mesa.';
  end if;
  select array_agg(x order by random()) into deck from generate_series(0, 51) x;
  i := 1;
  for pc in select e->>'id' jid, e->>'name' jname from jsonb_array_elements(g.players) e loop
    mine := array[deck[i], deck[i+1], deck[i+2]];
    i := i + 3;
    delete from trio_card where id = pc.jid;
    insert into trio_card (id, cards) values (pc.jid, to_jsonb(mine));
    update users set balance = balance - 10 where id = pc.jid;
    insert into ledger (date, uname, type, amount, detail, ts)
    values (to_char(now(), 'DD/MM/YYYY HH24:MI:SS'), pc.jname, 'Trío y Par', -10, 'Derecho de mesa (ante)', p_now);
    arr := arr || jsonb_build_object('id', pc.jid, 'name', pc.jname, 'ante', 10, 'bet', 0, 'folded', false, 'acted', false);
  end loop;
  board := array[deck[i], deck[i+1]];
  delete from trio_card where id = 'board';
  insert into trio_card (id, cards) values ('board', to_jsonb(board));
  update trio set
    phase = 'betting', players = arr, pot = 10 * n,
    board = '[]'::jsonb, round = 1, reveal_until = 0,
    round_end = p_now + 45000, dealer = (g.dealer + 1) % n, result = null
  where id = 1;
  return (select trio_state());
end $$;

create or replace function public.trio_bet(p_user_id text, p_amount int, p_now bigint)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  g trio%rowtype;
  u users;
  arr jsonb;
  idx int;
begin
  select * into g from trio where id = 1 for update;
  if g.phase <> 'betting' then raise exception 'Las apuestas están cerradas.'; end if;
  if p_now > g.round_end then raise exception 'El tiempo de apuesta se acabó.'; end if;
  select * into u from users where id = p_user_id for update;
  if not found then raise exception 'Sesión expirada.'; end if;
  if p_amount < 0 then raise exception 'Apuesta no válida (0 = pasar).'; end if;
  if u.balance < p_amount then raise exception 'No tienes suficientes fichas.'; end if;
  arr := g.players;
  idx := (select ord - 1 from jsonb_array_elements(arr) with ordinality as x(e, ord) where x.e->>'id' = p_user_id);
  if idx is null then raise exception 'No estás en esta mesa.'; end if;
  if (arr->idx->>'folded')::boolean then raise exception 'Ya te retiraste en esta ronda.'; end if;
  if (arr->idx->>'acted')::boolean then raise exception 'Ya actuaste esta ronda.'; end if;
  if p_amount > 0 then
    update users set balance = balance - p_amount where id = p_user_id;
    arr := jsonb_set(arr, array[idx::text], (arr->idx) || jsonb_build_object('bet', (arr->idx->>'bet')::int + p_amount), true);
    insert into ledger (date, uname, type, amount, detail, ts)
    values (to_char(now(), 'DD/MM/YYYY HH24:MI:SS'), u.name, 'Trío y Par', -p_amount, 'Apuesta en la mesa', p_now);
  end if;
  arr := jsonb_set(arr, array[idx::text], (arr->idx) || jsonb_build_object('acted', true), true);
  update trio set players = arr, pot = g.pot + p_amount where id = 1;
  perform trio_resolve(p_now);
  return (select trio_state());
end $$;

create or replace function public.trio_fold(p_user_id text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare g trio%rowtype; arr jsonb; idx int; active int;
begin
  select * into g from trio where id = 1 for update;
  if g.phase <> 'betting' then raise exception 'Las apuestas están cerradas.'; end if;
  arr := g.players;
  idx := (select ord - 1 from jsonb_array_elements(arr) with ordinality as x(e, ord) where x.e->>'id' = p_user_id);
  if idx is null then raise exception 'No estás en esta mesa.'; end if;
  if (arr->idx->>'folded')::boolean then return (select trio_state()); end if;
  active := (select count(*) from jsonb_array_elements(arr) e where not (e->>'folded')::boolean);
  if active <= 1 then raise exception 'No puedes retirarte: ya eres el último en pie.'; end if;
  arr := jsonb_set(arr, array[idx::text], (arr->idx) || jsonb_build_object('folded', true, 'acted', true), true);
  update trio set players = arr where id = 1;
  perform trio_resolve(extract(epoch from now())::bigint * 1000);
  return (select trio_state());
end $$;

-- Cierra la ronda si todos actuaron o si venció el tiempo; al final resuelve el bote.
-- Timeout => los que no actuaron pasan (check), NO se retiran.
-- Si solo queda 1 en pie, gana al instante.
create or replace function public.trio_resolve(p_now bigint)
returns void language plpgsql security definer set search_path = public as $$
declare
  g trio%rowtype;
  arr jsonb;
  board_cards jsonb;
  revealed jsonb;
  act_count int;
  all_acted boolean;
  time_up boolean;
  main_cards jsonb;
  w_score text; w_id text; w_name text; w_hand text; winners jsonb := '[]'::jsonb;
  cur_cards jsonb; cur_score text;
  total_prize int; base int; nw int; i int; hands jsonb := '[]'::jsonb;
begin
  select * into g from trio where id = 1 for update;
  if g.phase <> 'betting' then return; end if;

  act_count := (select count(*) from jsonb_array_elements(g.players) e where not (e->>'folded')::boolean);

  -- Degenerado: nadie activo (no debería pasar; el último no puede retirarse)
  if act_count = 0 then
    update trio set phase = 'done',
      result = jsonb_build_object('winner', null, 'name', 'Nadie', 'prize', 0, 'hand', 'Sin ganador')
    where id = 1;
    return;
  end if;

  -- Un solo jugador en pie: gana al instante sin esperar tiempo
  if act_count = 1 then
    w_id := (select e->>'id' from jsonb_array_elements(g.players) e where not (e->>'folded')::boolean limit 1);
    w_name := (select e->>'name' from jsonb_array_elements(g.players) e where not (e->>'folded')::boolean limit 1);
    w_hand := 'Todos se retiraron';
    base := floor(g.pot * 0.99);
    update users set balance = balance + base where id = w_id;
    insert into ledger (date, uname, type, amount, detail, ts)
    values (to_char(now(), 'DD/MM/YYYY HH24:MI:SS'), w_name, 'Trío y Par - Premio', base,
            'Único en pie. Casa retiene 1%', p_now);
    update trio set phase = 'done',
      result = jsonb_build_object('winner', w_id, 'name', w_name, 'prize', base, 'hand', w_hand)
    where id = 1;
    return;
  end if;

  time_up := p_now > g.round_end;
  all_acted := (select coalesce(bool_and((e->>'acted')::boolean), false)
                from jsonb_array_elements(g.players) e where not (e->>'folded')::boolean);

  if not time_up and not all_acted then
    return; -- esperar a que actúen o venza el tiempo
  end if;

  if time_up and not all_acted then
    -- los que no actuaron pasan (check), se marcan como actuados
    arr := (select jsonb_agg(
              case when (e->>'folded')::boolean or (e->>'acted')::boolean then e
                   else e || jsonb_build_object('acted', true, 'bet', 0) end
            ) from jsonb_array_elements(g.players) e);
    update trio set players = arr where id = 1;
    g.players := arr;
  end if;

  -- Revelar siguiente carta comunitaria o showdown
  if g.round < 3 then
    board_cards := (select cards from trio_card where id = 'board');
    revealed := g.board || jsonb_build_array(board_cards->(g.round - 1));
    update trio set
      round = g.round + 1,
      reveal_until = g.round + 1,
      board = revealed,
      round_end = p_now + 45000,
      players = (select jsonb_agg(
                   case when (e->>'folded')::boolean then e
                        else e || jsonb_build_object('bet', 0, 'acted', false) end
                 ) from jsonb_array_elements(g.players) e)
    where id = 1;
    return;
  end if;

  -- Showdown: 3 propias + 2 comunitarias
  board_cards := (select cards from trio_card where id = 'board');
  for i in 0..jsonb_array_length(g.players)-1 loop
    if (g.players->i->>'folded')::boolean then continue; end if;
    main_cards := (select cards from trio_card where id = g.players->i->>'id') || board_cards;
    cur_score := trio_score(main_cards);
    hands := hands || jsonb_build_object('id', g.players->i->>'id', 'name', g.players->i->>'name',
                                         'cards', main_cards, 'hand', trio_rankname(cur_score));
    if w_score is null or cur_score > w_score then
      w_score := cur_score; w_id := g.players->i->>'id'; w_name := g.players->i->>'name'; w_hand := trio_rankname(cur_score);
      winners := jsonb_build_array(g.players->i);
    elsif cur_score = w_score then
      winners := winners || g.players->i;
    end if;
  end loop;

  nw := jsonb_array_length(winners);
  if nw = 0 then
    update trio set phase = 'done',
      result = jsonb_build_object('winner', null, 'name', 'Nadie', 'prize', 0, 'hand', 'Sin ganador')
    where id = 1;
    return;
  end if;

  total_prize := floor(g.pot * 0.99);
  base := floor(total_prize / nw);
  for i in 0..nw-1 loop
    update users set balance = balance + base where id = winners->i->>'id';
    insert into ledger (date, uname, type, amount, detail, ts)
    values (to_char(now(), 'DD/MM/YYYY HH24:MI:SS'), winners->i->>'name', 'Trío y Par - Premio', base,
            w_hand || '. Casa retiene 1% del bote.', p_now + i);
  end loop;

  update trio set phase = 'done',
    result = jsonb_build_object('winner', w_id, 'name', w_name, 'prize', base, 'hand', w_hand, 'hands', hands)
  where id = 1;
end $$;

-- Las cartas privadas del usuario (o array vacío si no hay mano activa)
create or replace function public.trio_my_cards(p_user_id text)
returns jsonb language sql security definer set search_path = public as $$
  select coalesce((select cards from trio_card where id = p_user_id), '[]'::jsonb);
$$;

-- Llamada periódica de los clientes: resuelve rondas vencidas y devuelve el estado
create or replace function public.trio_tick(p_now bigint)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  perform trio_resolve(p_now);
  return (select trio_state());
end $$;

-- ============ ACCESOS ============
grant execute on function public.trio_state() to anon, authenticated;
grant execute on function public.trio_join(text) to anon, authenticated;
grant execute on function public.trio_leave(text) to anon, authenticated;
grant execute on function public.trio_deal(bigint) to anon, authenticated;
grant execute on function public.trio_bet(text, int, bigint) to anon, authenticated;
grant execute on function public.trio_fold(text) to anon, authenticated;
grant execute on function public.trio_resolve(bigint) to anon, authenticated;
grant execute on function public.trio_tick(bigint) to anon, authenticated;
grant execute on function public.trio_my_cards(text) to anon, authenticated;
grant execute on function public.trio_score(jsonb) to anon, authenticated;
grant execute on function public.trio_rankname(text) to anon, authenticated;

insert into public.trio (id) values (1) on conflict do nothing;