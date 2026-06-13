-- =====================================================================
--  ROTA DO PET — PASSO FINAL: trancar a tabela antiga rdp_store
--  ⚠️ SÓ RODAR DEPOIS que o index.html novo estiver publicado na Vercel!
--  (o site antigo em produção ainda lê/grava nesta tabela; trancar antes
--   do deploy derruba o site no ar)
-- =====================================================================

alter table public.rdp_store enable row level security;
revoke all on public.rdp_store from anon, authenticated;
-- sem nenhuma policy criada = ninguém acessa via API (nem leitura nem escrita)
