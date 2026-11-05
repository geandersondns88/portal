// Chama a API de assinaturas de um sistema cadastrado em `sistemas` (ex.: Transporte), em nome do administrador logado.
// A chave de cada sistema fica num segredo desta função, cujo NOME está em sistemas.chave_segredo (PORTAL_KEY_*); nunca vai para a tela.
// Corpo: { sistema: 'transporte', acao: 'testar' | 'listar' | 'eventos' | 'ativar' | 'suspender' | 'cancelar' | 'estender_teste' | 'trocar_plano' | 'planos_listar' | 'plano_salvar' | 'plano_excluir', ...campos da ação }
import { bancoDeServico, exigirAdministrador, responder, respostaOpcoes } from '../_shared/comum.ts'

const ACOES = ['listar', 'eventos', 'ativar', 'suspender', 'cancelar', 'estender_teste', 'trocar_plano', 'planos_listar', 'plano_salvar', 'plano_excluir']

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return respostaOpcoes()
  if (req.method !== 'POST') return responder({ erro: 'Método não permitido.' }, 405)

  const banco = bancoDeServico()
  const adm = await exigirAdministrador(req, banco)
  if (adm instanceof Response) return adm

  let corpo: Record<string, unknown>
  try {
    const lido = await req.json()
    if (typeof lido !== 'object' || lido === null || Array.isArray(lido)) throw new Error('forma')
    corpo = lido as Record<string, unknown>
  } catch {
    return responder({ erro: 'Dados inválidos.' }, 400)
  }
  const { sistema: codigo, acao: acaoPedida, ...resto } = corpo
  if (typeof codigo !== 'string' || typeof acaoPedida !== 'string') return responder({ erro: 'Informe o sistema e a ação.' }, 400)
  const testar = acaoPedida === 'testar'
  if (!testar && !ACOES.includes(acaoPedida)) return responder({ erro: 'Ação inválida.' }, 400)

  const { data: sistema, error: erroSistema } = await banco.from('sistemas').select('id, url_api, chave_segredo, ativo').eq('codigo', codigo).maybeSingle()
  if (erroSistema) {
    console.error('sistemas:', erroSistema.message)
    return responder({ erro: 'Algo deu errado. Tente novamente.' }, 500)
  }
  if (!sistema || !sistema.ativo) return responder({ erro: 'Sistema não encontrado.' }, 404)
  if (!/^https:\/\//.test(sistema.url_api) || !/^PORTAL_KEY_[A-Z0-9_]+$/.test(sistema.chave_segredo)) return responder({ erro: 'Cadastro do sistema inválido.' }, 500)
  const chave = Deno.env.get(sistema.chave_segredo)
  if (!chave) return responder({ erro: `O segredo ${sistema.chave_segredo} ainda não foi cadastrado neste projeto.` }, 503)

  const acao = testar ? 'listar' : acaoPedida
  const pedido = testar ? { acao: 'listar', limite: 1 } : { acao, ...resto }
  const inicio = Date.now()
  let status = 0
  let resposta: Record<string, unknown> | null = null
  try {
    const r = await fetch(sistema.url_api, { method: 'POST', headers: { 'Content-Type': 'application/json', 'x-portal-key': chave }, body: JSON.stringify(pedido), signal: AbortSignal.timeout(15000) })
    status = r.status
    resposta = await r.json().catch(() => null)
  } catch (erro) {
    console.error('chamar-sistema:', (erro as Error).message)
  }
  const ok = status >= 200 && status < 300 && resposta?.ok === true

  // registro: sem a chave e, na listagem, só o total (os dados das empresas não são copiados para o log)
  const resumo = resposta === null ? null : acao === 'listar' ? { ok: resposta.ok ?? false, total: resposta.total ?? null, erro: resposta.erro ?? null } : resposta
  await banco.from('chamadas_aos_sistemas').insert({ sistema_id: sistema.id, acao: testar ? 'testar' : acao, pedido: testar ? {} : pedido, resposta: resumo, ok })

  if (testar) return responder({ ok, status, milissegundos: Date.now() - inicio, total: resposta?.total ?? null, erro: ok ? null : (resposta?.erro ?? 'Sem resposta do sistema.') }, 200)
  if (resposta === null) return responder({ erro: 'Sem resposta do sistema.' }, 502)
  return responder(resposta, status >= 200 && status < 600 ? status : 502)
})
