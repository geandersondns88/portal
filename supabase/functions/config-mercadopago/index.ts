// Configuração do Mercado Pago do portal. Só administrador. O access_token e o webhook_secret NUNCA são devolvidos: a tela vê só os 4 últimos caracteres.
// Corpo: { acao: 'ler' } | { acao: 'salvar', ambiente, public_key, access_token?, webhook_secret?, url_notificacao? } | { acao: 'testar' }
// Em 'salvar', campo de segredo vazio ou ausente mantém o valor guardado; { limpar: ['access_token', 'webhook_secret'] } apaga.
import { bancoDeServico, exigirAdministrador, responder, respostaOpcoes } from '../_shared/comum.ts'

const CREDENCIAL = /^(APP_USR|TEST)-[A-Za-z0-9_-]{10,300}$/
const final = (v: string | null) => (v ? `••••${v.slice(-4)}` : null)

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return respostaOpcoes()
  if (req.method !== 'POST') return responder({ erro: 'Método não permitido.' }, 405)

  const banco = bancoDeServico()
  const adm = await exigirAdministrador(req, banco)
  if (adm instanceof Response) return adm

  let c: Record<string, unknown>
  try {
    const lido = await req.json()
    if (typeof lido !== 'object' || lido === null || Array.isArray(lido)) throw new Error('forma')
    c = lido as Record<string, unknown>
  } catch {
    return responder({ erro: 'Dados inválidos.' }, 400)
  }

  const { data: atual, error } = await banco.from('config_mercadopago').select('*').maybeSingle()
  if (error) {
    console.error('config_mercadopago:', error.message)
    return responder({ erro: 'Algo deu errado. Tente novamente.' }, 500)
  }
  const visao = (l: typeof atual) => ({
    ambiente: l?.ambiente ?? 'teste',
    public_key: l?.public_key ?? '',
    url_notificacao: l?.url_notificacao ?? '',
    access_token_final: final(l?.access_token ?? null),
    webhook_secret_final: final(l?.webhook_secret ?? null),
    atualizado_em: l?.atualizado_em ?? null,
  })

  if (c.acao === 'ler') return responder({ ok: true, config: visao(atual) })

  if (c.acao === 'testar') {
    if (!atual?.access_token) return responder({ erro: 'Salve o access token antes de testar.' }, 400)
    try {
      const r = await fetch('https://api.mercadopago.com/users/me', { headers: { Authorization: `Bearer ${atual.access_token}` }, signal: AbortSignal.timeout(15000) })
      const corpo = await r.json().catch(() => ({}))
      if (!r.ok) return responder({ ok: false, erro: 'O Mercado Pago recusou o access token.' })
      return responder({ ok: true, conta: { id: corpo.id ?? null, apelido: corpo.nickname ?? null, pais: corpo.site_id ?? null } })
    } catch (e) {
      console.error('mercadopago:', (e as Error).message)
      return responder({ ok: false, erro: 'Não foi possível falar com o Mercado Pago.' })
    }
  }

  if (c.acao !== 'salvar') return responder({ erro: 'Ação inválida.' }, 400)

  const texto = (v: unknown, nome: string, max: number): string | null | Response => {
    if (v === undefined || v === null || v === '') return null
    if (typeof v !== 'string' || v.trim().length > max) return responder({ erro: `${nome} inválido.` }, 400)
    return v.trim()
  }
  const ambiente = c.ambiente
  if (ambiente !== 'teste' && ambiente !== 'producao') return responder({ erro: 'Escolha o ambiente (teste ou produção).' }, 400)
  const pub = texto(c.public_key, 'Public key', 300)
  const tok = texto(c.access_token, 'Access token', 300)
  const sec = texto(c.webhook_secret, 'Segredo do webhook', 200)
  const url = texto(c.url_notificacao, 'URL de notificação', 300)
  for (const v of [pub, tok, sec, url]) if (v instanceof Response) return v
  if (pub && !CREDENCIAL.test(pub as string)) return responder({ erro: 'A public key deve começar com APP_USR- ou TEST-.' }, 400)
  if (tok && !CREDENCIAL.test(tok as string)) return responder({ erro: 'O access token deve começar com APP_USR- ou TEST-.' }, 400)
  if (url && !/^https:\/\/[^\s]+$/.test(url as string)) return responder({ erro: 'A URL de notificação deve começar com https://.' }, 400)
  const limpar = Array.isArray(c.limpar) ? c.limpar : []

  const novo = {
    id: true,
    ambiente,
    public_key: pub ?? atual?.public_key ?? null,
    access_token: limpar.includes('access_token') ? null : ((tok as string | null) ?? atual?.access_token ?? null),
    webhook_secret: limpar.includes('webhook_secret') ? null : ((sec as string | null) ?? atual?.webhook_secret ?? null),
    url_notificacao: url ?? null,
    atualizado_em: new Date().toISOString(),
    atualizado_por: adm.userId,
  }
  const { error: erroGravar } = await banco.from('config_mercadopago').upsert(novo)
  if (erroGravar) {
    console.error('config_mercadopago upsert:', erroGravar.message)
    return responder({ erro: 'Algo deu errado. Tente novamente.' }, 500)
  }
  return responder({ ok: true, config: visao(novo as typeof atual) })
})
