-- ===========================================================================
--  TRIO  (reglas oficiales del juego de mesa de Kaya Miyano)  -  v2
-- ---------------------------------------------------------------------------
--  36 cartas: numeros 1..12 en 3 copias.  2 a 6 jugadores.
--  Reparto:  2 jug -> 12 + 12 centro | 3 jug -> 9 + 9 | 4 jug -> 7 + 8
--            5 jug -> 6 + 6 | 6 jug -> 5 + 6     (siempre suman 36)
--  La partida arranca sola en cuanto se sientan 2 jugadores.
--
--  TURNO: revelar de a una carta, sacada del centro o pidiendole a cualquier
--  jugador (incluido tu mismo) su carta mas BAJA o mas ALTA.
--    * 2 cartas distintas  -> se devuelven todas y termina el turno.
--    * 2 cartas iguales    -> se revela la 3a.
--    * 3 iguales           -> te llevas el trio.
--  VICTORIA: 3 trios  o  el trio de 7 (victoria inmediata).
--
--  La mesa retiene el 1% del bote.  Ante = 10 fichas.
-- ===========================================================================

-- ---------- limpieza de la version anterior (poker) ----------
drop function if exists public.trio_state();
drop function if exists public.trio_join(text);
drop function if exists public.trio_leave(text);
drop function if exists public.trio_deal(bigint);
drop function if exists public.trio_bet(text, int, bigint);
drop function if exists public.trio_fold(text);
drop function if exists public.trio_resolve(bigint);
drop function if exists public.trio_tick(bigint);
drop function if exists public.trio_my_cards(text);
drop function if exists public.trio_score(jsonb);
drop function if exists public.trio_rankname(text);
drop table if exists public.trio_card;

drop function if exists public.trio_state(text);
drop function if exists public.trio_deal(text);
drop function if exists public.trio_reveal(text, text, text, int);
drop function if exists public.trio_tick(text);
drop function if exists public.trio_resolve_now(bigint);
drop function if exists public.trio_turn_advance();
drop function if exists public.trio_maintain();

drop table if exists public.trio;

-- ---------- mesa ----------
create table public.trio (
  id           int    primary key default 1 check (id = 1),
  phase        text   not null default 'waiting',   -- waiting | playing | done
  players      jsonb  not null default '[]'::jsonb, -- [{id,name,hand:[1..12],trios:[v]}]
  middle       jsonb  not null default '[]'::jsonb, -- [{v,d:true} | {e:true}]
  pot          int    not null default 0,
  turn         int    not null default 0,           -- indice en players
  turn_end     bigint not null default 0,           -- ms (servidor)
  target       int    not null default 3,           -- trios necesarios
  revealed     jsonb  not null default '[]'::jsonb, -- [{v,type:'mid'|'hand',idx,pid}]
  resolve_kind text,                                -- mismatch | trio | win
  resolve_at   bigint not null default 0,
  result       jsonb,
  game_no      int    not null default 0
);

-- RLS activado SIN politicas: nadie (anon) puede leer la mesa via REST.
-- Solo las funciones security definer (owner=postgres) la tocan.
alter table public.trio enable row level security;

insert into public.trio (id) values (1) on conflict do nothing;

-- constante de tiempo de turno (ms)
create or replace function public.trio_turn_ms() returns int
language sql immutable as $$ select 20000 $$;

-- ===========================================================================
--  INTERNAS (no se conceden a anon/authenticated)
-- ===========================================================================

-- Pasa el turno: devuelve las cartas reveladas, borra el marcador de jugada
-- pendiente y marca el nuevo limite de tiempo (servidor).
create or replace function public.trio_turn_advance() returns void
language plpgsql security definer set search_path = public as $$
declare
  g trio%rowtype;
  n int;
  nowms bigint;
begin
  select * into g from trio where id = 1 for update;
  if g.phase <> 'playing' then return; end if;
  nowms := (extract(epoch from now()) * 1000)::bigint;
  n := jsonb_array_length(g.players);
  if n = 0 then
    update trio set phase = 'waiting', turn = 0, turn_end = 0, pot = 0,
      players = '[]'::jsonb, middle = '[]'::jsonb,
      revealed = '[]'::jsonb, resolve_kind = null, resolve_at = 0, result = null
    where id = 1;
    return;
  end if;
  update trio set
    turn = (g.turn + 1) % n,
    turn_end = nowms + trio_turn_ms(),
    revealed = '[]'::jsonb,
    resolve_kind = null,
    resolve_at = 0
  where id = 1;
end $$;

-- Resuelve la jugada pendiente (mismatch -> devolver y pasar turno;
-- trio -> pasar turno; win -> pagar y cerrar la partida).
create or replace function public.trio_resolve_now(p_now bigint) returns void
language plpgsql security definer set search_path = public as $$
declare
  g trio%rowtype;
  k text;
  w_id text;
  w_name text;
  prize int;
  hands jsonb;
  reason text;
begin
  select * into g from trio where id = 1 for update;
  if g.phase <> 'playing' then return; end if;
  k := g.resolve_kind;
  if k is null then return; end if;

  if k = 'win' then
    w_id   := g.players->g.turn->>'id';
    w_name := g.players->g.turn->>'name';
    reason := case when jsonb_array_length(g.players->g.turn->'trios') >= 3
                   then 'trios3' else 'trio7' end;
    prize  := floor(g.pot * 0.99)::int;
    update users set balance = balance + prize where id = w_id;
    insert into ledger (date, uname, type, amount, detail, ts)
    values (to_char(now(), 'DD/MM/YYYY HH24:MI:SS'), w_name, 'Trio - Premio', prize,
            'Trio completo. La casa retiene 1% del bote.', p_now);
    select coalesce(jsonb_agg(
             jsonb_build_object('id', e->>'id', 'name', e->>'name',
                                'hand', e->'hand', 'trios', e->'trios') order by o), '[]'::jsonb)
      into hands
      from jsonb_array_elements(g.players) with ordinality t(e, o);
    update trio set phase = 'done', result = jsonb_build_object(
        'winner', w_id, 'name', w_name, 'prize', prize, 'reason', reason, 'players', hands),
      resolve_kind = null, resolve_at = 0, revealed = '[]'::jsonb
    where id = 1;
    return;
  end if;

  -- mismatch o trio: se acabó la jugada, pasa el turno
  perform trio_turn_advance();
end $$;

-- Se invoca desde los clientes (trio_tick). Aplica lo que este vencido.
create or replace function public.trio_maintain() returns void
language plpgsql security definer set search_path = public as $$
declare
  g trio%rowtype;
  nowms bigint;
begin
  select * into g from trio where id = 1 for update;
  if g.phase <> 'playing' then return; end if;
  nowms := (extract(epoch from now()) * 1000)::bigint;
  if g.resolve_kind is not null and nowms >= g.resolve_at then
    perform trio_resolve_now(nowms);
    return;
  end if;
  if g.resolve_kind is null and nowms > g.turn_end then
    perform trio_turn_advance();
  end if;
end $$;

-- ===========================================================================
--  ESTADO PARA EL CLIENTE  (oculta las manos ajenas y las cartas del centro)
-- ===========================================================================
create or replace function public.trio_state(p_user_id text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  out jsonb;
begin
  select jsonb_build_object(
    'phase',        g.phase,
    'pot',          g.pot,
    'turn',         g.turn,
    'turn_end',     g.turn_end,
    'target',       g.target,
    'game_no',      g.game_no,
    'resolve_kind', g.resolve_kind,
    'resolve_at',   g.resolve_at,
    'revealed',     g.revealed,
    'result',       g.result,
    'server_now',   (extract(epoch from now()) * 1000)::bigint,
    'middle', (
      select coalesce(jsonb_agg(
        case when m ? 'e' then jsonb_build_object('e', true)
             else jsonb_build_object('d', true) end order by o), '[]'::jsonb)
      from jsonb_array_elements(g.middle) with ordinality t(m, o)
    ),
    'players', (
      select coalesce(jsonb_agg(
        (e || jsonb_build_object(
           'hand',     case when e->>'id' = p_user_id then e->'hand' else null end,
           'hand_len', coalesce(jsonb_array_length(e->'hand'), 0)
         )) order by o), '[]'::jsonb)
      from jsonb_array_elements(g.players) with ordinality t(e, o)
    )
  ) into out from trio g where id = 1;
  return out;
end $$;

create or replace function public.trio_tick(p_user_id text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  perform trio_maintain();
  return (select trio_state(p_user_id));
end $$;

-- ===========================================================================
--  RPC PUBLICAS
-- ===========================================================================

create or replace function public.trio_join(p_user_id text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  me users;
  g trio%rowtype;
begin
  select * into me from users where id = p_user_id;
  if not found then raise exception 'Sesion expirada. Cierra y vuelve a entrar.'; end if;
  if me.admin then raise exception 'La cuenta de administracion no puede jugar.'; end if;
  select * into g from trio where id = 1 for update;
  if g.phase = 'playing' then raise exception 'La partida ya empezo. Espera a que termine.'; end if;
  if exists (select 1 from jsonb_array_elements(g.players) e where e->>'id' = p_user_id) then
    return (select trio_state(p_user_id));
  end if;
  if jsonb_array_length(g.players) >= 6 then
    raise exception 'La mesa esta llena (maximo 6 jugadores).';
  end if;
  update trio set players = g.players || jsonb_build_array(
    jsonb_build_object('id', me.id, 'name', me.name, 'hand', '[]'::jsonb, 'trios', '[]'::jsonb))
  where id = 1;

  -- con 2 sentados (todos con saldo) la partida arranca sola
  if (select jsonb_array_length(players) from trio where id = 1) >= 2
     and (select count(*) from jsonb_array_elements((select players from trio where id = 1)) e
           join users u on u.id = e->>'id' where u.balance < 10) = 0 then
    perform public.trio_do_deal();
  end if;

  return (select trio_state(p_user_id));
end $$;

-- Levantarse.  Durante la partida tus cartas vuelven al centro (boca abajo),
-- tu ante se queda en el bote y pasa el turno; si quedan menos de 3 se
-- interrumpe la partida y se reparte el bote entre los que quedan.
create or replace function public.trio_leave(p_user_id text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  g trio%rowtype;
  j int;
  n int;
  newn int;
  nt int;
  arr jsonb;
  hand jsonb;
  k int;
  share int;
  pc record;
begin
  select * into g from trio where id = 1 for update;
  select t.o - 1 into j from jsonb_array_elements(g.players) with ordinality t(e, o)
   where t.e->>'id' = p_user_id;
  if j is null then return (select trio_state(p_user_id)); end if;

  if g.phase = 'playing' then
    hand := g.players->j->'hand';
    for k in 0 .. coalesce(jsonb_array_length(hand), 0) - 1 loop
      g.middle := g.middle || jsonb_build_object('v', (hand->>k)::int, 'd', true);
    end loop;
  end if;

  arr := (select coalesce(jsonb_agg(e order by o), '[]'::jsonb)
            from jsonb_array_elements(g.players) with ordinality t(e, o)
           where t.o - 1 <> j);
  n := jsonb_array_length(g.players);
  newn := jsonb_array_length(arr);

  if g.phase <> 'playing' then
    update trio set players = arr where id = 1;
    return (select trio_state(p_user_id));
  end if;

  if j < g.turn then nt := g.turn - 1;
  elsif newn > 0 then nt := g.turn % newn;
  else nt := 0; end if;

  if newn < 2 then
    share := case when newn > 0 then floor(g.pot / newn)::int else 0 end;
    for pc in select e->>'id' uid, e->>'name' uname from jsonb_array_elements(arr) e loop
      update users set balance = balance + share where id = pc.uid;
      insert into ledger (date, uname, type, amount, detail, ts)
      values (to_char(now(), 'DD/MM/YYYY HH24:MI:SS'), pc.uname, 'Trio', share,
              'Mesa interrumpida: reparto del bote.', (extract(epoch from now()) * 1000)::bigint);
    end loop;
    update trio set phase = 'waiting', players = arr, middle = '[]'::jsonb, pot = 0,
      turn = 0, turn_end = 0, revealed = '[]'::jsonb, resolve_kind = null,
      resolve_at = 0, result = null
    where id = 1;
  else
    update trio set players = arr, middle = g.middle, turn = nt,
      turn_end = (extract(epoch from now()) * 1000)::bigint + trio_turn_ms(),
      revealed = '[]'::jsonb, resolve_kind = null, resolve_at = 0
    where id = 1;
  end if;
  return (select trio_state(p_user_id));
end $$;

-- Repartir (interno).  Cada sentado paga 10 de ante.
create or replace function public.trio_do_deal() returns void
language plpgsql security definer set search_path = public as $$
declare
  g trio%rowtype;
  deck int[];
  n int;
  hs int;
  ms int;
  i int;
  k int;
  arr jsonb := '[]'::jsonb;
  mid jsonb := '[]'::jsonb;
  hand int[];
  pc record;
  nowms bigint;
begin
  select * into g from trio where id = 1 for update;
  if g.phase = 'playing' then raise exception 'Ya hay una partida en curso.'; end if;
  n := jsonb_array_length(g.players);
  if n < 2 then raise exception 'Se necesitan al menos 2 jugadores para repartir.'; end if;
  if n > 6 then raise exception 'Maximo 6 jugadores.'; end if;
  if exists (select 1 from jsonb_array_elements(g.players) e join users u on u.id = e->>'id'
              where u.balance < 10) then
    raise exception 'Todos los sentados deben tener al menos 10 fichas.';
  end if;

  select array_agg(x order by random()) into deck from generate_series(1, 36) x;
  hs := case n when 2 then 12 when 3 then 9 when 4 then 7 when 5 then 6 else 5 end;
  ms := case n when 2 then 12 when 3 then 9 when 4 then 8 when 5 then 6 else 6 end;
  nowms := (extract(epoch from now()) * 1000)::bigint;
  i := 1;

  for pc in select e->>'id' uid, e->>'name' uname
              from jsonb_array_elements(g.players) e loop
    hand := deck[i:i + hs - 1];
    i := i + hs;
    -- valor 1..12 de cada carta 1..36
    hand := (select array_agg(((c - 1) % 12) + 1 order by ((c - 1) % 12) + 1) from unnest(hand) as c);
    arr := arr || jsonb_build_object('id', pc.uid, 'name', pc.uname,
             'hand', (select coalesce(jsonb_agg(x order by x), '[]'::jsonb) from unnest(hand) x),
             'trios', '[]'::jsonb);
    update users set balance = balance - 10 where id = pc.uid;
    insert into ledger (date, uname, type, amount, detail, ts)
    values (to_char(now(), 'DD/MM/YYYY HH24:MI:SS'), pc.uname, 'Trio', -10,
            'Ante de la mesa (Trio).', nowms);
  end loop;

  for k in 1 .. ms loop
    mid := mid || jsonb_build_object('v', ((deck[i] - 1) % 12) + 1, 'd', true);
    i := i + 1;
  end loop;

  update trio set phase = 'playing', players = arr, middle = mid, pot = 10 * n,
    turn = (g.game_no + 1) % n, turn_end = nowms + trio_turn_ms(), target = 3,
    revealed = '[]'::jsonb, resolve_kind = null, resolve_at = 0,
    result = null, game_no = g.game_no + 1
  where id = 1;
end $$;

-- Repartir (publico).  Solo valida que el que llama este sentado.
create or replace function public.trio_deal(p_user_id text)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from jsonb_array_elements((select players from trio where id = 1)) e
                  where e->>'id' = p_user_id) then
    raise exception 'Siéntate en la mesa primero.';
  end if;
  perform trio_do_deal();
  return (select trio_state(p_user_id));
end $$;

-- Revelar UNA carta en tu turno.
--   p_type = 'mid'      -> p_idx = posicion en el centro
--   p_type = 'low'/'high' -> p_pid = jugador al que le pides (puede ser tu mismo);
--                            el servidor revela su carta mas baja/alta todavia
--                            no revelada en este turno.
create or replace function public.trio_reveal(p_user_id text, p_type text,
                                              p_pid text default null, p_idx int default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  g trio%rowtype;
  nowms bigint;
  cnt int;
  val int := null;
  j   int := null;
  rev jsonb;
  tgt jsonb;
  same boolean;
  pidx int;
  pcard int;
  hv jsonb;
  win boolean;
  r jsonb;
begin
  select * into g from trio where id = 1 for update;
  if g.phase <> 'playing' then raise exception 'No hay ninguna partida en curso.'; end if;
  if g.resolve_kind is not null then
    raise exception 'Espera: la jugada anterior todavia se esta resolviendo.';
  end if;
  nowms := (extract(epoch from now()) * 1000)::bigint;
  if nowms > g.turn_end then
    perform trio_turn_advance();
    return (select trio_state(p_user_id));
  end if;
  if (g.players->g.turn->>'id') <> p_user_id then
    raise exception 'No es tu turno.';
  end if;
  cnt := jsonb_array_length(g.revealed);
  if cnt >= 3 then raise exception 'Tu turno ya no puede seguir.'; end if;

  if p_type = 'mid' then
    if p_idx is null or p_idx < 0 or p_idx >= jsonb_array_length(g.middle) then
      raise exception 'Carta no valida.';
    end if;
    if (g.middle->p_idx) ? 'e' then raise exception 'Esa carta ya se ha tomado.'; end if;
    if exists (select 1 from jsonb_array_elements(g.revealed) x
                where x->>'type' = 'mid' and (x->>'idx')::int = p_idx) then
      raise exception 'Esa carta ya se ha revelado en este turno.';
    end if;
    val := (g.middle->p_idx->>'v')::int;
    rev := jsonb_build_object('v', val, 'type', 'mid', 'idx', p_idx);

  elsif p_type in ('low', 'high') then
    select e into tgt from jsonb_array_elements(g.players) e where e->>'id' = p_pid;
    if tgt is null then raise exception 'Ese jugador no esta en la mesa.'; end if;
    select x.v, x.o - 1 into val, j
      from jsonb_array_elements_text(tgt->'hand') with ordinality x(v, o)
     where not exists (
        select 1 from jsonb_array_elements(g.revealed) y
         where y->>'type' = 'hand' and y->>'pid' = p_pid and (y->>'idx')::int = x.o - 1)
     order by x.v::int asc
     limit 1;
    if p_type = 'high' then
      val := null; j := null;
      select x.v, x.o - 1 into val, j
        from jsonb_array_elements_text(tgt->'hand') with ordinality x(v, o)
       where not exists (
          select 1 from jsonb_array_elements(g.revealed) y
           where y->>'type' = 'hand' and y->>'pid' = p_pid and (y->>'idx')::int = x.o - 1)
       order by x.v::int desc
       limit 1;
    end if;
    if val is null then
      raise exception 'Ese jugador ya no tiene cartas por revelar en este turno.';
    end if;
    rev := jsonb_build_object('v', val, 'type', 'hand', 'pid', p_pid, 'idx', j);

  else
    raise exception 'Accion no valida.';
  end if;

  g.revealed := g.revealed || jsonb_build_array(rev);
  cnt := jsonb_array_length(g.revealed);

  select count(distinct (x->>'v')::int) = 1 into same
    from jsonb_array_elements(g.revealed) x;

  if not same then
    -- las cartas no coinciden: se devuelven y termina el turno (con pausa)
    update trio set revealed = g.revealed,
      resolve_kind = 'mismatch', resolve_at = nowms + 1600
    where id = 1;
    return (select trio_state(p_user_id));
  end if;

  if cnt < 3 then
    -- segunda carta correcta: falta la tercera
    update trio set revealed = g.revealed where id = 1;
    return (select trio_state(p_user_id));
  end if;

  -- =====================  TRIO COMPLETO  =====================
  for r in select x from jsonb_array_elements(g.revealed) x where x->>'type' = 'mid' loop
    pidx := (r->>'idx')::int;
    g.middle := jsonb_set(g.middle, array[pidx::text], '{"e":true}'::jsonb, true);
  end loop;

  for r in select x from jsonb_array_elements(g.revealed) x where x->>'type' = 'hand'
           order by (x->>'pid'), (x->>'idx')::int desc loop
    pcard := (r->>'idx')::int;
    select t.o - 1 into pidx from jsonb_array_elements(g.players) with ordinality t(e, o)
     where t.e->>'id' = r->>'pid';
    if pidx is null then continue; end if;
    select coalesce(jsonb_agg(x.e order by x.o), '[]'::jsonb) into hv
      from jsonb_array_elements(g.players->pidx->'hand') with ordinality x(e, o)
     where x.o - 1 <> pcard;
    g.players := jsonb_set(g.players, array[pidx::text],
                 (g.players->pidx) || jsonb_build_object('hand', hv), true);
  end loop;

  val := (rev->>'v')::int;
  g.players := jsonb_set(g.players, array[g.turn::text],
               (g.players->g.turn) || jsonb_build_object('trios',
                 (g.players->g.turn->'trios') || jsonb_build_array(val::int)), true);

  select jsonb_array_length(g.players->g.turn->'trios') >= 3
      or exists (select 1 from jsonb_array_elements_text(g.players->g.turn->'trios') x
                  where x::int = 7)
    into win;

  update trio set players = g.players, middle = g.middle, revealed = '[]'::jsonb,
    resolve_kind = case when win then 'win' else 'trio' end,
    resolve_at = nowms + 1600
  where id = 1;

  return (select trio_state(p_user_id));
end $$;

-- ===========================================================================
--  ACCESOS
-- ===========================================================================
revoke execute on function public.trio_state(text)          from public, anon, authenticated;
revoke execute on function public.trio_tick(text)           from public, anon, authenticated;
revoke execute on function public.trio_turn_advance()       from public, anon, authenticated;
revoke execute on function public.trio_resolve_now(bigint)  from public, anon, authenticated;
revoke execute on function public.trio_maintain()           from public, anon, authenticated;
revoke execute on function public.trio_do_deal()            from public, anon, authenticated;
revoke execute on function public.trio_turn_ms()            from public, anon, authenticated;

grant execute on function public.trio_state(text)   to anon, authenticated;
grant execute on function public.trio_tick(text)    to anon, authenticated;
grant execute on function public.trio_join(text)    to anon, authenticated;
grant execute on function public.trio_leave(text)   to anon, authenticated;
grant execute on function public.trio_deal(text)    to anon, authenticated;
grant execute on function public.trio_reveal(text, text, text, int) to anon, authenticated;
