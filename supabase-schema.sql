-- ============ CASINO EL DORADO — Esquema Supabase ============
-- Tablas, funciones seguras (RPC) y políticas de acceso.

create table if not exists public.users (
  id text primary key,
  name text not null,
  pass text not null,
  balance int not null default 0,
  avatar text not null default '',
  admin boolean not null default false,
  created bigint not null default 0
);

create table if not exists public.rounds (
  id text primary key,
  start bigint not null,
  ends bigint not null,
  participants jsonb not null default '[]'::jsonb,
  finished boolean not null default false,
  winner_id text,
  winner_name text,
  winner_index int not null default -1,
  prize int not null default 0,
  finished_at bigint not null default 0
);

create table if not exists public.scratch_stats (
  id int primary key default 1 check (id = 1),
  cards int not null default 0,
  bets int not null default 0,
  paid int not null default 0
);
insert into public.scratch_stats (id, cards, bets, paid) values (1, 0, 0, 0) on conflict do nothing;

create table if not exists public.ledger (
  id bigint generated always as identity primary key,
  date text not null default '',
  uname text not null default '',
  type text not null default '',
  amount int not null default 0,
  detail text not null default '',
  ts bigint not null default 0
);

-- ============ VISTA SEGURA DE USUARIOS (sin contraseñas) ============
create or replace view public.v_users as
  select id, name, balance, avatar, admin from public.users;
grant select on public.v_users to anon, authenticated;

-- ============ FUNCIONES (toda escritura pasa por aquí, atómica) ============

create or replace function public.register_user(p_id text, p_name text, p_pass text, p_balance int, p_admin boolean, p_created bigint)
returns void language plpgsql security definer set search_path = public as $$
begin
  if exists(select 1 from users where id = p_id) then
    raise exception 'Ese usuario ya existe.';
  end if;
  insert into users (id, name, pass, balance, avatar, admin, created)
  values (p_id, p_name, p_pass, p_balance, '', p_admin, p_created);
end $$;

create or replace function public.login(p_id text, p_pass text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare the_id text; the_name text; the_bal int; the_av text; the_admin bool;
begin
  select id, name, balance, avatar, admin into the_id, the_name, the_bal, the_av, the_admin
    from users where id = p_id and pass = p_pass;
  if not found then
    return null;
  end if;
  return jsonb_build_object('id', the_id, 'name', the_name, 'balance', the_bal, 'avatar', the_av, 'admin', the_admin);
end $$;

create or replace function public.get_user(p_id text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare the_id text; the_name text; the_bal int; the_av text; the_admin bool;
begin
  select id, name, balance, avatar, admin into the_id, the_name, the_bal, the_av, the_admin
    from users where id = p_id;
  if not found then
    return null;
  end if;
  return jsonb_build_object('id', the_id, 'name', the_name, 'balance', the_bal, 'avatar', the_av, 'admin', the_admin);
end $$;

create or replace function public.change_password(p_id text, p_pass text)
returns void language plpgsql security definer set search_path = public as $$
begin
  update users set pass = p_pass where id = p_id;
end $$;

create or replace function public.set_avatar(p_id text, p_avatar text)
returns void language plpgsql security definer set search_path = public as $$
begin
  update users set avatar = p_avatar where id = p_id;
end $$;

create or replace function public.ensure_round(p_id text, p_now bigint, p_end bigint, p_delay bigint)
returns void language plpgsql security definer set search_path = public as $$
declare r rounds;
begin
  select * into r from rounds where id = p_id for update;
  if not found then
    insert into rounds (id, start, ends, participants, finished, winner_id, winner_name, winner_index, prize, finished_at)
    values (p_id, p_now, p_end, '[]'::jsonb, false, null, null, -1, 0, 0);
  elsif r.finished and p_now - coalesce(r.finished_at, 0) >= p_delay then
    update rounds set start = p_now, ends = p_end, participants = '[]'::jsonb,
      finished = false, winner_id = null, winner_name = null, winner_index = -1, prize = 0, finished_at = 0
    where id = p_id;
  end if;
end $$;

create or replace function public.join_round(p_round text, p_user_id text, p_cost int, p_label text, p_now bigint)
returns jsonb language plpgsql security definer set search_path = public as $$
declare u users; r rounds; ps jsonb;
begin
  select * into u from users where id = p_user_id for update;
  if not found then raise exception 'Sesión expirada. Cierra y vuelve a entrar.'; end if;
  select * into r from rounds where id = p_round for update;
  if not found then raise exception 'La ronda se está cargando.'; end if;
  if r.finished or p_now >= r.ends then
    raise exception 'La ronda está terminando. Espera la siguiente.';
  end if;
  ps := r.participants;
  if exists (select 1 from jsonb_array_elements(ps) e where e->>'id' = p_user_id) then
    raise exception 'Ya estás participando en esta ronda.';
  end if;
  if u.balance < p_cost then
    raise exception 'No tienes suficientes fichas. Necesitas % fichas.', p_cost;
  end if;
  update users set balance = balance - p_cost where id = p_user_id;
  update rounds set participants = ps || jsonb_build_array(jsonb_build_object('id', p_user_id, 'name', u.name)) where id = p_round;
  insert into ledger (date, uname, type, amount, detail, ts)
  values (to_char(now(), 'DD/MM/YYYY HH24:MI:SS'), u.name, p_label, -p_cost, 'Participación en ' || lower(p_label), p_now);
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.settle_round(p_round text, p_label text, p_cost int, p_now bigint)
returns void language plpgsql security definer set search_path = public as $$
declare
  r rounds; ps jsonb; n int; wi int; w_el jsonb; total int;
  v_prize int; v_admin int; v_jack int; w users; date_txt text;
begin
  select * into r from rounds where id = p_round for update;
  if not found or r.finished then return; end if;
  if p_now < r.ends then return; end if;
  ps := r.participants; n := jsonb_array_length(ps);
  date_txt := to_char(now(), 'DD/MM/YYYY HH24:MI:SS');
  if n = 0 then
    update rounds set finished = true, finished_at = p_now, winner_id = null, winner_name = null, winner_index = -1, prize = 0
    where id = p_round;
    insert into ledger (date, uname, type, amount, detail, ts)
    values (date_txt, 'SISTEMA', p_label, 0, 'Ronda finalizada sin participantes.', p_now);
    return;
  end if;
  wi := floor(random() * n); w_el := ps->wi;
  total := n * p_cost;
  v_prize := floor(total * 0.90); v_admin := floor(total * 0.05); v_jack := total - v_prize - v_admin;
  update rounds set finished = true, finished_at = p_now,
    winner_id = w_el->>'id', winner_name = w_el->>'name', winner_index = wi, prize = v_prize
  where id = p_round;
  select * into w from users where id = w_el->>'id';
  if found then
    update users set balance = balance + v_prize where id = w_el->>'id';
  end if;
  insert into ledger (date, uname, type, amount, detail, ts)
  values (date_txt, w_el->>'name', p_label || ' - Premio', v_prize,
          'Ganador de la ronda. Participantes: ' || n || '. Premio: ' || v_prize || ' fichas.', p_now);
  insert into ledger (date, uname, type, amount, detail, ts)
  values (date_txt, 'SISTEMA', p_label, 0,
          'Fondo administración: ' || v_admin || ' fichas. Fondo acumulado: ' || v_jack || ' fichas.', p_now + 1);
end $$;

create or replace function public.send_fichas(p_from text, p_to text, p_amount int, p_now bigint)
returns void language plpgsql security definer set search_path = public as $$
declare me users; to_u users;
begin
  select * into me from users where id = p_from for update;
  if not found then raise exception 'Sesión expirada. Cierra y vuelve a entrar.'; end if;
  if p_from = p_to then raise exception 'No puedes enviarte fichas a ti mismo.'; end if;
  select * into to_u from users where id = p_to for update;
  if not found then raise exception 'No existe ningún usuario con ese ID.'; end if;
  if me.balance < p_amount then raise exception 'Saldo insuficiente.'; end if;
  update users set balance = balance - p_amount where id = p_from;
  update users set balance = balance + p_amount where id = p_to;
  insert into ledger (date, uname, type, amount, detail, ts)
  values (to_char(now(), 'DD/MM/YYYY HH24:MI:SS'), me.name, 'Transferencia', p_amount,
          'Envío a ' || to_u.name || ' (' || p_to || ')', p_now);
end $$;

create or replace function public.admin_adjust(p_to text, p_amount int, p_sign int, p_now bigint)
returns void language plpgsql security definer set search_path = public as $$
declare u users; new_bal int; date_txt text;
begin
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

create or replace function public.scratch_buy(p_user_id text, p_price int, p_now bigint)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  u users; s scratch_stats%rowtype; budget int; prize int; rr int; new_bal int; date_txt text;
begin
  select * into u from users where id = p_user_id for update;
  if not found then raise exception 'Sesión expirada. Cierra y vuelve a entrar.'; end if;
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
  update users set balance = new_bal where id = p_user_id;
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

-- ============ ACCESOS Y POLÍTICAS ============
grant execute on function
  public.register_user(text,text,text,int,boolean,bigint),
  public.login(text,text),
  public.get_user(text),
  public.change_password(text,text),
  public.set_avatar(text,text),
  public.ensure_round(text,bigint,bigint,bigint),
  public.join_round(text,text,int,text,bigint),
  public.settle_round(text,text,int,bigint),
  public.send_fichas(text,text,int,bigint),
  public.admin_adjust(text,int,int,bigint),
  public.scratch_buy(text,int,bigint)
  to anon, authenticated;

alter table public.users enable row level security;
alter table public.rounds enable row level security;
alter table public.ledger enable row level security;
alter table public.scratch_stats enable row level security;

-- los clientes solo pueden LEER (el tiempo real se alimenta de esto); toda
-- escritura va por las funciones (security definer) de arriba.
drop policy if exists "sel_all_rounds" on public.rounds;
create policy "sel_all_rounds" on public.rounds for select using (true);
drop policy if exists "sel_all_ledger" on public.ledger;
create policy "sel_all_ledger" on public.ledger for select using (true);
drop policy if exists "sel_all_stats" on public.scratch_stats;
create policy "sel_all_stats" on public.scratch_stats for select using (true);
-- users: sin SELECT directo (evita exponer hashes); usar v_users o rpc.