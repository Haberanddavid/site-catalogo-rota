-- =====================================================================
--  ROTA DO PET — Setup de Segurança (tabelas reais + RLS + funções)
--  Onde rodar: Supabase → Dashboard → SQL Editor → New query → cole tudo → Run
--  Pode rodar mais de uma vez sem problema (é idempotente).
-- =====================================================================

-- pgcrypto: necessário para guardar senha com hash (bcrypt)
create extension if not exists pgcrypto;

-- =====================================================================
-- 1) CATÁLOGO — dados públicos da loja (categorias, produtos, cupons,
--    frete, config). Mesmo formato chave-valor de hoje.
--    Regra: QUALQUER UM lê; só o ADMIN autenticado grava.
-- =====================================================================
create table if not exists public.catalog (
  store_key  text primary key,
  data       jsonb not null,
  updated_at timestamptz not null default now()
);
alter table public.catalog enable row level security;

drop policy if exists catalog_public_read on public.catalog;
create policy catalog_public_read on public.catalog
  for select using (true);

drop policy if exists catalog_admin_write on public.catalog;
create policy catalog_admin_write on public.catalog
  for all
  using (auth.uid() is not null)
  with check (auth.uid() is not null);

-- =====================================================================
-- 2) PEDIDOS — uma linha por pedido.
--    Regra: o cliente NÃO grava direto. O pedido entra pela função
--    place_order() (mais abaixo), que também desconta o estoque.
--    Só o ADMIN lê/altera/exclui. Ninguém lê pedido dos outros.
-- =====================================================================
create table if not exists public.orders (
  id         bigint primary key,           -- usa o Date.now() gerado no site
  created_at timestamptz not null default now(),
  phone      text not null,
  name       text,
  status     text not null default 'pendente',
  payload    jsonb not null                -- itens, total, endereço, etc.
);
alter table public.orders enable row level security;

drop policy if exists orders_admin_read on public.orders;
create policy orders_admin_read on public.orders
  for select using (auth.uid() is not null);

drop policy if exists orders_admin_update on public.orders;
create policy orders_admin_update on public.orders
  for update using (auth.uid() is not null) with check (auth.uid() is not null);

drop policy if exists orders_admin_delete on public.orders;
create policy orders_admin_delete on public.orders
  for delete using (auth.uid() is not null);

-- =====================================================================
-- 3) CONTAS DE CLIENTES — uma linha por cliente.
--    Regra: NINGUÉM acessa direto (anon). Tudo passa pelas funções
--    abaixo (que checam a senha). Só o ADMIN consegue listar.
--    A senha é guardada com hash bcrypt (nunca em texto puro).
-- =====================================================================
create table if not exists public.accounts (
  phone         text primary key,
  name          text not null,
  password_hash text not null,
  address       jsonb,
  created_at    timestamptz not null default now()
);
alter table public.accounts enable row level security;

drop policy if exists accounts_admin_read on public.accounts;
create policy accounts_admin_read on public.accounts
  for select using (auth.uid() is not null);
-- (sem policy de insert/update/select para anon = bloqueado; usa as RPCs)

-- ---------------------------------------------------------------------
-- Funções de conta do cliente (SECURITY DEFINER = rodam com permissão
-- elevada, mas só fazem exatamente o que está escrito e nunca vazam
-- dados de outro cliente).
-- ---------------------------------------------------------------------

-- Existe conta com esse telefone?
create or replace function public.customer_phone_exists(p_phone text)
returns boolean
language sql security definer set search_path = public as $$
  select exists(select 1 from accounts where phone = p_phone);
$$;

-- Cadastro de novo cliente
create or replace function public.customer_register(
  p_phone text, p_name text, p_password text, p_address jsonb default null
) returns json
language plpgsql security definer set search_path = public as $$
begin
  if length(coalesce(p_password,'')) < 4 then
    return json_build_object('ok', false, 'error', 'senha_curta');
  end if;
  if exists(select 1 from accounts where phone = p_phone) then
    return json_build_object('ok', false, 'error', 'ja_existe');
  end if;
  insert into accounts(phone, name, password_hash, address)
  values (p_phone, p_name, crypt(p_password, gen_salt('bf')), p_address);
  return json_build_object('ok', true, 'name', p_name);
end;
$$;

-- Login: confere a senha e devolve o perfil + os pedidos do cliente
create or replace function public.customer_login(p_phone text, p_password text)
returns json
language plpgsql security definer set search_path = public as $$
declare acc accounts%rowtype; ords json;
begin
  select * into acc from accounts where phone = p_phone;
  if not found then
    return json_build_object('ok', false, 'error', 'nao_existe');
  end if;
  if acc.password_hash <> crypt(p_password, acc.password_hash) then
    return json_build_object('ok', false, 'error', 'senha_incorreta');
  end if;
  select coalesce(json_agg(o.payload order by o.created_at desc), '[]'::json)
    into ords from orders o where o.phone = p_phone;
  return json_build_object('ok', true,
    'name', acc.name, 'address', acc.address, 'orders', ords);
end;
$$;

-- Atualizar nome/endereço/senha (precisa da senha atual para confirmar)
create or replace function public.customer_update(
  p_phone text, p_password text,
  p_name text default null, p_address jsonb default null, p_new_password text default null
) returns json
language plpgsql security definer set search_path = public as $$
declare acc accounts%rowtype;
begin
  select * into acc from accounts where phone = p_phone;
  if not found then return json_build_object('ok', false, 'error', 'nao_existe'); end if;
  if acc.password_hash <> crypt(p_password, acc.password_hash) then
    return json_build_object('ok', false, 'error', 'senha_incorreta');
  end if;
  update accounts set
    name = coalesce(p_name, name),
    address = coalesce(p_address, address),
    password_hash = case when p_new_password is not null and length(p_new_password) >= 4
                         then crypt(p_new_password, gen_salt('bf')) else password_hash end
  where phone = p_phone;
  return json_build_object('ok', true);
end;
$$;

-- Redefinir senha (cliente esqueceu) — confere telefone + nome cadastrado
create or replace function public.customer_reset_password(
  p_phone text, p_name text, p_new_password text
) returns json
language plpgsql security definer set search_path = public as $$
declare acc accounts%rowtype;
begin
  if length(coalesce(p_new_password,'')) < 4 then
    return json_build_object('ok', false, 'error', 'senha_curta');
  end if;
  select * into acc from accounts where phone = p_phone;
  if not found then return json_build_object('ok', false, 'error', 'nao_existe'); end if;
  if lower(trim(acc.name)) <> lower(trim(p_name)) then
    return json_build_object('ok', false, 'error', 'nome_incorreto');
  end if;
  update accounts set password_hash = crypt(p_new_password, gen_salt('bf')) where phone = p_phone;
  return json_build_object('ok', true);
end;
$$;

-- ---------------------------------------------------------------------
-- Função para CRIAR PEDIDO (a única forma do cliente gerar pedido).
-- Insere a linha em orders E desconta o estoque no catálogo, tudo no
-- servidor. O pedido deve trazer "cartItems": [{id, qty}, ...].
-- ---------------------------------------------------------------------
create or replace function public.place_order(p_order jsonb)
returns json
language plpgsql security definer set search_path = public as $$
declare
  v_id    bigint := coalesce((p_order->>'id')::bigint, (extract(epoch from now())*1000)::bigint);
  v_phone text   := regexp_replace(coalesce(p_order->>'phone',''), '\D', '', 'g');
  prods   jsonb;
  item    jsonb;
  i       int;
begin
  insert into orders(id, phone, name, status, payload)
  values (v_id, v_phone, p_order->>'name', coalesce(p_order->>'status','pendente'), p_order)
  on conflict (id) do nothing;

  -- desconta estoque (se o pedido trouxe a lista de itens)
  if p_order ? 'cartItems' then
    select data into prods from catalog where store_key = 'rdp2_prods' for update;
    if prods is not null then
      for item in select * from jsonb_array_elements(p_order->'cartItems') loop
        for i in 0 .. jsonb_array_length(prods) - 1 loop
          if (prods->i->>'id') = (item->>'id') then
            prods := jsonb_set(prods, array[i::text, 'stock'],
              to_jsonb(greatest(0, coalesce((prods->i->>'stock')::int,0) - coalesce((item->>'qty')::int,0))));
          end if;
        end loop;
      end loop;
      update catalog set data = prods, updated_at = now() where store_key = 'rdp2_prods';
    end if;
  end if;

  return json_build_object('ok', true, 'id', v_id);
end;
$$;

-- Liberar o uso das funções para visitantes (anon) e admin
grant execute on function public.place_order(jsonb)                          to anon, authenticated;
grant execute on function public.customer_phone_exists(text)                to anon, authenticated;
grant execute on function public.customer_register(text,text,text,jsonb)     to anon, authenticated;
grant execute on function public.customer_login(text,text)                   to anon, authenticated;
grant execute on function public.customer_update(text,text,text,jsonb,text)  to anon, authenticated;
grant execute on function public.customer_reset_password(text,text,text)     to anon, authenticated;

-- =====================================================================
-- 4) MIGRAÇÃO — copia os dados que já existem na tabela antiga
--    (rdp_store) para as novas tabelas. Rode UMA vez.
--    Se a tabela rdp_store não existir mais, ignore esta seção.
-- =====================================================================

-- 4.1 Catálogo
insert into public.catalog(store_key, data)
select store_key, data from public.rdp_store
where store_key in ('rdp2_cats','rdp2_prods','rdp2_coupons','rdp2_ship','rdp2_cfg')
on conflict (store_key) do update set data = excluded.data, updated_at = now();

-- 4.2 Pedidos (explode o array rdp2_orders em linhas)
insert into public.orders(id, phone, name, status, payload, created_at)
select (o->>'id')::bigint,
       regexp_replace(coalesce(o->>'phone',''), '\D', '', 'g'),
       o->>'name',
       coalesce(o->>'status','pendente'),
       o,
       coalesce(to_timestamp((o->>'id')::bigint / 1000.0), now())
from public.rdp_store, jsonb_array_elements(data) as o
where store_key = 'rdp2_orders'
on conflict (id) do nothing;

-- 4.3 Contas (explode o objeto {telefone: {...}} em linhas).
--     As senhas antigas estavam em texto puro; aqui viram hash bcrypt.
insert into public.accounts(phone, name, password_hash, address)
select key,
       coalesce(value->>'name','Cliente'),
       crypt(coalesce(value->>'password','1234'), gen_salt('bf')),
       value->'address'
from public.rdp_store, jsonb_each(data)
where store_key = 'rdp2_accounts'
on conflict (phone) do nothing;

-- =====================================================================
-- FIM. Depois de rodar:
--   1) Vá em Authentication → Users → Add user → crie SEU usuário admin
--      (e-mail + senha). É com ele que você vai entrar no painel.
--   2) (Opcional, recomendado) Authentication → Providers → Email:
--      desligue "Enable email signups" para ninguém criar admin sozinho.
-- =====================================================================
