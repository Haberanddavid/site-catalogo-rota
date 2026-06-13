// Vercel Serverless Function — importa dados de um produto a partir de um link.
// Lê a página do link e extrai título, descrição e imagem (via tags Open Graph,
// as mesmas que geram o preview de link no WhatsApp). Sem dependências externas.
//
// Uso: GET /api/import-product?url=https://loja.com/produto
// Retorno: { ok:true, title, description, image, price } | { ok:false, error }

// Extrai o content de uma <meta> por property/name (og:title, twitter:image, etc.)
function meta(html, key) {
  // tenta property="key" ... content="..."  e a ordem inversa content="..." property="key"
  const patterns = [
    new RegExp('<meta[^>]+(?:property|name)=["\']' + key + '["\'][^>]+content=["\']([^"\']*)["\']', 'i'),
    new RegExp('<meta[^>]+content=["\']([^"\']*)["\'][^>]+(?:property|name)=["\']' + key + '["\']', 'i'),
  ];
  for (const re of patterns) {
    const m = html.match(re);
    if (m && m[1]) return decode(m[1].trim());
  }
  return '';
}

// Decodifica as entidades HTML mais comuns
function decode(s) {
  return s
    .replace(/&amp;/g, '&').replace(/&lt;/g, '<').replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"').replace(/&#0?39;|&apos;/g, "'").replace(/&nbsp;/g, ' ')
    .replace(/&#(\d+);/g, (_, n) => String.fromCharCode(+n));
}

// Tenta achar um preço no texto (R$ 99,90 / 99.90). Heurística — o admin confere.
function guessPrice(html) {
  const m = html.match(/R\$\s*([0-9]{1,3}(?:\.[0-9]{3})*,[0-9]{2}|[0-9]+[.,][0-9]{2})/);
  if (!m) return null;
  let v = m[1];
  if (v.includes(',')) v = v.replace(/\./g, '').replace(',', '.'); // 1.299,90 -> 1299.90
  const n = parseFloat(v);
  return isNaN(n) ? null : n;
}

// Resolve URL relativa da imagem em relação à página
function absUrl(src, base) {
  try { return new URL(src, base).href; } catch { return src; }
}

module.exports = async function handler(req, res) {
  res.setHeader('Access-Control-Allow-Origin', '*');
  const url = (req.query && req.query.url) || '';
  if (!url || !/^https?:\/\//i.test(url)) {
    return res.status(400).json({ ok: false, error: 'Informe uma URL válida (http/https).' });
  }
  try {
    const ctrl = new AbortController();
    const timer = setTimeout(() => ctrl.abort(), 12000);
    const resp = await fetch(url, {
      signal: ctrl.signal,
      headers: {
        // alguns sites recusam sem User-Agent de navegador
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120 Safari/537.36',
        'Accept': 'text/html,application/xhtml+xml',
      },
    });
    clearTimeout(timer);
    if (!resp.ok) {
      const motivo = (resp.status === 403 || resp.status === 401)
        ? 'esse site bloqueia leitura automática'
        : `o site respondeu ${resp.status}`;
      return res.status(200).json({ ok: false, error: `Não deu para importar (${motivo}). Preencha manualmente abaixo.` });
    }

    const html = (await resp.text()).slice(0, 600000); // limita p/ não estourar memória

    const title = meta(html, 'og:title') || meta(html, 'twitter:title') ||
      (html.match(/<title[^>]*>([^<]*)<\/title>/i)?.[1] || '').trim();
    const description = meta(html, 'og:description') || meta(html, 'twitter:description') ||
      meta(html, 'description');
    let image = meta(html, 'og:image') || meta(html, 'og:image:url') || meta(html, 'twitter:image');
    if (image) image = absUrl(image, resp.url || url);
    const price = guessPrice(html);

    if (!title && !image) {
      return res.status(200).json({ ok: false, error: 'Não encontrei dados do produto nesse link (o site pode bloquear leitura automática).' });
    }
    return res.status(200).json({ ok: true, title: decode(title || ''), description: decode(description || ''), image: image || '', price });
  } catch (e) {
    const msg = e.name === 'AbortError' ? 'O site demorou demais para responder.' : 'Não consegui acessar esse link.';
    return res.status(200).json({ ok: false, error: msg });
  }
}
