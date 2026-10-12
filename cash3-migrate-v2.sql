-- Migración a Cash 3 v2 (número con dos montos a la vez)
drop function if exists public.cash3_place(text, text, text, integer, bigint);
drop function if exists public.cash3_state(text);
drop function if exists public.cash3_admin_info(text);
drop function if exists public.cash3_admin_settle(text, text, bigint);
drop table if exists public.cash3_bet;
