-- =====================================================================
--  ROTA DO PET — Correção: funções não achavam gen_salt/crypt
--  (no Supabase o pgcrypto fica no schema "extensions"; as funções
--   estavam com search_path só em "public")
--  Onde rodar: Supabase → SQL Editor → New query → cole tudo → Run
-- =====================================================================

create extension if not exists pgcrypto with schema extensions;

-- Recria as 4 funções que usam senha, agora enxergando o schema extensions

create or replace function public.customer_register(
  p_phone text, p_name text, p_password text, p_address jsonb default null
) returns json
language plpgsql security definer set search_path = public, extensions as $$
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

create or replace function public.customer_login(p_phone text, p_password text)
returns json
language plpgsql security definer set search_path = public, extensions as $$
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

create or replace function public.customer_update(
  p_phone text, p_password text,
  p_name text default null, p_address jsonb default null, p_new_password text default null
) returns json
language plpgsql security definer set search_path = public, extensions as $$
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

create or replace function public.customer_reset_password(
  p_phone text, p_name text, p_new_password text
) returns json
language plpgsql security definer set search_path = public, extensions as $$
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

-- Migra as contas antigas que ficaram de fora (se a migração 4.3 do
-- setup falhou pelo mesmo motivo, esta parte completa o serviço)
insert into public.accounts(phone, name, password_hash, address)
select key,
       coalesce(value->>'name','Cliente'),
       extensions.crypt(coalesce(value->>'password','1234'), extensions.gen_salt('bf')),
       value->'address'
from public.rdp_store, jsonb_each(data)
where store_key = 'rdp2_accounts'
on conflict (phone) do nothing;
