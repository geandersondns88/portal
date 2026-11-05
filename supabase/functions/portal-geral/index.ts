// Visão geral do portal, só para administrador.
// { acao: 'sistemas' }  → sistemas ativos (código e nome) para montar a tela de clientes.
// { acao: 'saude' }     → testa de verdade cada comunicação (o próprio banco do portal, cada sistema e o Mercado Pago) e devolve as últimas chamadas.
// A chave de cada sistema e o access token do Mercado Pago ficam no servidor: a tela só recebe o resultado (operacional, falha ou não configurado).
import { bancoDeServico, exigirAdministrador, responder, respostaOpcoes } from '../_shared/comum.ts'

type Estado = 'ok' | 'falha' | 'nao_configurado'
type Item = { chave: string; nome: string; estado: Estado; milissegundos: number | null; detalhe: string | null }

async function verificarSistema(banco: ReturnType<typeof bancoDeServico>, s: { id: string; codigo: string; nome: string; url_api: string; chave_segredo: string }): Promise<Item> {
  const base = { chave: `sistema:${s.codigo}`, nome: s.nome }
  if (!/^https:\/\//.test(s.url_api) || !/^PORTAL_KEY_[A-Z0-9_]+$/.test(s.chave_segredo)) return { ...base, estado: 'falha', milissegundos: null, detalhe: 'Cadastro do sistema inválido.' }
  const chave = Deno.env.get(s.chave_segredo)
  if (!chave) return { ...base, estado: 'nao_configurado', milissegundos: null, detalhe: `O segredo ${s.chave_segredo} não foi cadastrado no portal.` }
  const inicio = Date.now()
  let estado: Estado = 'falha'
  let detalhe: string | null = 'Sem resposta do sistema.'
  let resumo: Record<string, unknown> | null = null
  try {
    const r = await fetch(s.url_api, { method: 'POST', headers: { 'Content-Type': 'application/json', 'x-portal-key': chave }, body: JSON.stringify({ acao: 'listar', limite: 1 }), signal: AbortSignal.timeout(10000) })
    const corpo = await r.json().catch(() => null)
    if (r.ok && corpo?.ok === true) {
      estado = 'ok'
      detalhe = `${Number(corpo.total ?? 0)} empresa(s) cadastrada(s)`
    } else {
      detalhe = typeof corpo?.erro === 'string' ? corpo.erro : `O sistema respondeu com erro (HTTP ${r.status}).`
    }
    resumo = { ok: estado === 'ok', total: corpo?.total ?? null, erro: corpo?.erro ?? null }
  } catch (e) {
    console.error('saude sistema:', s.codigo, (e as Error).message)
    detalhe = 'Não foi possível falar com o sistema.'
  }
  const ms = Date.now() - inicio
  await banco.from('chamadas_aos_sistemas').insert({ sistema_id: s.id, acao: 'saude', pedido: {}, resposta: resumo, ok: estado === 'ok' })
  return { ...base, estado, milissegundos: ms, detalhe }
}

async function verificarMercadoPago(banco: ReturnType<typeof bancoDeServico>): Promise<Item> {
  const base = { chave: 'mercadopago', nome: 'Mercado Pago' }
  const { data, error } = await banco.from('config_mercadopago').select('access_token').maybeSingle()
  if (error) return { ...base, estado: 'falha', milissegundos: null, detalhe: 'Não foi possível ler a configuração.' }
  if (!data?.access_token) return { ...base, estado: 'nao_configurado', milissegundos: null, detalhe: 'Credenciais ainda não cadastradas.' }
  const inicio = Date.now()
  try {
    const r = await fetch('https://api.mercadopago.com/users/me', { headers: { Authorization: `Bearer ${data.access_token}` }, signal: AbortSignal.timeout(10000) })
    return r.ok
      ? { ...base, estado: 'ok', milissegundos: Date.now() - inicio, detalhe: 'Credenciais aceitas.' }
      : { ...base, estado: 'falha', milissegundos: Date.now() - inicio, detalhe: 'O Mercado Pago recusou o access token.' }
  } catch (e) {
    console.error('saude mercadopago:', (e as Error).message)
    return { ...base, estado: 'falha', milissegundos: null, detalhe: 'Não foi possível falar com o Mercado Pago.' }
  }
}

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

  if (c.acao === 'sistemas') {
    const { data, error } = await banco.from('sistemas').select('codigo, nome').eq('ativo', true).order('nome')
    if (error) {
      console.error('sistemas:', error.message)
      return responder({ erro: 'Algo deu errado. Tente novamente.' }, 500)
    }
    return responder({ ok: true, sistemas: data ?? [] })
  }

  if (c.acao === 'saude') {
    const inicioBanco = Date.now()
    const { data: sistemas, error } = await banco.from('sistemas').select('id, codigo, nome, url_api, chave_segredo').eq('ativo', true).order('nome')
    const itens: Item[] = [
      error
        ? { chave: 'banco', nome: 'Banco de dados do portal', estado: 'falha', milissegundos: null, detalhe: 'Não foi possível consultar o banco.' }
        : { chave: 'banco', nome: 'Banco de dados do portal', estado: 'ok', milissegundos: Date.now() - inicioBanco, detalhe: null },
    ]
    itens.push(...(await Promise.all((sistemas ?? []).map((s) => verificarSistema(banco, s)))))
    itens.push(await verificarMercadoPago(banco))

    const { data: chamadas } = await banco.from('chamadas_aos_sistemas').select('acao, ok, created_at, sistemas(nome)').order('created_at', { ascending: false }).limit(15)
    const resumo = { ok: 0, falha: 0, nao_configurado: 0 }
    for (const i of itens) resumo[i.estado] += 1
    return responder({
      ok: true,
      verificado_em: new Date().toISOString(),
      itens,
      resumo,
      chamadas: (chamadas ?? []).map((l: Record<string, unknown>) => ({ acao: l.acao, ok: l.ok, quando: l.created_at, sistema: (l.sistemas as { nome?: string } | null)?.nome ?? null })),
    })
  }

  return responder({ erro: 'Ação inválida.' }, 400)
})
