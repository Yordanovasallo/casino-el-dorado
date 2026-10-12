-- ============================================================
-- MEJORAS DE ADMINISTRACIÓN
-- 1) ID numérico único e irrepetible por usuario (columna num)
-- 2) El admin puede eliminar usuarios
-- 3) El admin puede ver ganancias/pérdidas y datos de cada usuario
-- ============================================================

-- ---------- 1) ID numérico único ----------
create sequence if not exists public.users_num_seq start with 1000;
alter table public.users add column if not exists num bigint;
update public.users set num = nextval('public.users_num_seq') where num is null;
select setval('public.users_num_seq', (select max(num) from public.users));
alter table public.users alter column num set default nextval('public.users_num_seq');
alter table public.users alter column num set not null;
create unique index if not exists users_num_uidx on public.users (num);

-- La vista que usa el panel incluye ahora el número
drop view if exists public.v_users;
create view public.v_users as
  select id, num, name, balance, avatar, admin, created from public.users;

-- ---------- login / get_user: devuelven el número, permiten entrar con número ----------
create or replace function public.login(p_id text, p_pass text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare r users;
begin
  if p_id ~ '^[0-9]+$' then
    select * into r from users where num = p_id::bigint and pass = p_pass;
  end if;
  if r.id is null then
    select * into r from users where id = p_id and pass = p_pass;
  end if;
  if r.id is null then return null; end if;
  return jsonb_build_object('id', r.id, 'num', r.num, 'name', r.name,
                            'balance', r.balance, 'avatar', r.avatar, 'admin', r.admin);
end $$;

create or replace function public.get_user(p_id text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare r users;
begin
  if p_id ~ '^[0-9]+$' then
    select * into r from users where num = p_id::bigint;
  end if;
  if r.id is null then
    select * into r from users where id = p_id;
  end if;
  if r.id is null then return null; end if;
  return jsonb_build_object('id', r.id, 'num', r.num, 'name', r.name,
                            'balance', r.balance, 'avatar', r.avatar, 'admin', r.admin);
end $$;

-- ---------- send_fichas: acepta el número de ID o el usuario ----------
create or replace function public.send_fichas(p_from text, p_to text, p_amount integer, p_now bigint)
returns void language plpgsql security definer set search_path = public as $$
declare me users; to_u users; v_to text := p_to; date_txt text;
begin
  select * into me from users where id = p_from for update;
  if not found then raise exception 'Sesión expirada. Cierra y vuelve a entrar.'; end if;
  if p_to ~ '^[0-9]+$' then
    select id into v_to from users where num = p_to::bigint;
    if v_to is null then raise exception 'No existe ningún usuario con ese ID.'; end if;
  end if;
  if p_from = v_to then raise exception 'No puedes enviarte fichas a ti mismo.'; end if;
  select * into to_u from users where id = v_to for update;
  if not found then raise exception 'No existe ningún usuario con ese ID.'; end if;
  if me.balance < p_amount then raise exception 'Saldo insuficiente.'; end if;
  update users set balance = balance - p_amount where id = p_from;
  update users set balance = balance + p_amount where id = v_to;
  date_txt := to_char(now(), 'DD/MM/YYYY HH24:MI:SS');
  insert into ledger (date, uname, type, amount, detail, ts)
  values (date_txt, me.name, 'Transferencia', p_amount,
          'Envío a ' || to_u.name || ' (#' || to_u.num || ')', p_now);
  insert into ledger (date, uname, type, amount, detail, ts)
  values (date_txt, to_u.name, 'Transferencia recibida', p_amount,
          'Recibido de ' || me.name || ' (#' || me.num || ')', p_now);
end $$;

-- ---------- admin_adjust con verificación de admin ----------
drop function if exists public.admin_adjust(text, integer, integer, bigint);
create or replace function public.admin_adjust(p_admin text, p_to text, p_amount integer, p_sign integer, p_now bigint)
returns void language plpgsql security definer set search_path = public as $$
declare u users; new_bal int; date_txt text;
begin
  if not exists (select 1 from users where id = p_admin and admin) then
    raise exception 'Solo el administrador puede ajustar fichas.'; end if;
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

-- ---------- lista de usuarios para el panel ----------
create or replace function public.admin_users_list(p_admin text)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from users where id = p_admin and admin) then
    raise exception 'Solo el administrador.'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object('id', id, 'num', num, 'name', name,
             'balance', balance, 'admin', admin, 'created', created)
           order by created desc, num desc)
    from users), '[]'::jsonb);
end $$;

-- ---------- eliminar usuario ----------
create or replace function public.admin_delete_user(p_admin text, p_user_id text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare nm text; adm boolean;
begin
  if not exists (select 1 from users where id = p_admin and admin) then
    raise exception 'Solo el administrador puede eliminar usuarios.'; end if;
  select name, admin into nm, adm from users where id = p_user_id;
  if nm is null then raise exception 'Ese usuario no existe.'; end if;
  if adm then raise exception 'No puedes eliminar una cuenta de administración.'; end if;
  if p_user_id = p_admin then raise exception 'No puedes eliminarte a ti mismo.'; end if;
  delete from bets where user_id = p_user_id;
  delete from ledger where uname = nm;
  update rounds set participants = coalesce((
      select jsonb_agg(e) from jsonb_array_elements(participants) e where e->>'id' <> p_user_id
    ), '[]'::jsonb)
    where jsonb_typeof(participants) = 'array';
  delete from users where id = p_user_id;
  return jsonb_build_object('ok', true, 'name', nm);
end $$;

-- ---------- estadísticas de un usuario ----------
create or replace function public.admin_user_stats(p_admin text, p_user_id text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  u users; bytype jsonb; last jsonb; won int := 0; lost int := 0;
  recargas int := 0; retiros int := 0; trans int := 0; tot int := 0;
  bets_agg jsonb; rw jsonb;
begin
  if not exists (select 1 from users where id = p_admin and admin) then
    raise exception 'Solo el administrador.'; end if;
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

-- ---------- permisos ----------
grant execute on function public.login(text, text) to anon, authenticated;
grant execute on function public.get_user(text) to anon, authenticated;
grant execute on function public.send_fichas(text, text, integer, bigint) to anon, authenticated;
grant execute on function public.admin_adjust(text, text, integer, integer, bigint) to anon, authenticated;
grant execute on function public.admin_users_list(text) to anon, authenticated;
grant execute on function public.admin_delete_user(text, text) to anon, authenticated;
grant execute on function public.admin_user_stats(text, text) to anon, authenticated;