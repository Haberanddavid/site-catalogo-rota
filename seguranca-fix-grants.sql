-- =====================================================================
--  ROTA DO PET — Correção: permissões das tabelas novas
--  (o seguranca-setup.sql criou as tabelas e o RLS, mas faltou o GRANT;
--   sem isso até a leitura pública do catálogo retorna 401)
--  Onde rodar: Supabase → SQL Editor → New query → cole tudo → Run
-- =====================================================================

-- Catálogo: qualquer um lê (o RLS já limita a escrita ao admin)
grant select on public.catalog to anon;
grant select, insert, update, delete on public.catalog to authenticated;

-- Pedidos: só o admin autenticado lê/altera/exclui
-- (a inserção é feita pela função place_order, que roda com permissão própria)
grant select, update, delete on public.orders to authenticated;

-- Contas: só o admin autenticado lista
grant select on public.accounts to authenticated;
