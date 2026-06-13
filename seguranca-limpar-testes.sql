-- =====================================================================
--  ROTA DO PET — Limpeza dos dados de TESTE
--  Apaga a conta e o pedido fictícios criados durante a validação
--  e devolve o estoque da "Ração Premium Cães Adultos" para 14.
--  Onde rodar: Supabase → SQL Editor → New query → cole tudo → Run
-- =====================================================================

-- 1) apaga o(s) pedido(s) de teste (telefone fictício 00900000001)
delete from public.orders where phone = '00900000001';

-- 2) apaga a conta de teste
delete from public.accounts where phone = '00900000001';

-- 3) devolve o estoque que o pedido de teste descontou
--    (primeiro produto = id 1, volta para 14)
update public.catalog
set data = (
  select jsonb_agg(
    case when (p->>'id') = '1'
         then jsonb_set(p, '{stock}', '14'::jsonb)
         else p end)
  from jsonb_array_elements(data) as p
),
updated_at = now()
where store_key = 'rdp2_prods';
