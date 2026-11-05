// Aviso de cadastro novo, enviado pelo próprio sistema (ex.: Transporte) quando uma empresa se cadastra: cria o cliente e a assinatura aqui
// (teste de 15 dias vem do sistema). Sem login de usuário (verify_jwt = false): quem chama prova com a MESMA chave que o portal usa para falar
// com o sistema (segredo PORTAL_KEY_<SISTEMA> aqui = PORTAL_API_KEY lá), no cabeçalho x-portal-key.
// Corpo: { sistema: 'transporte', empresa: { empresa_id, nome, nome_fantasia, documento, email, telefone, plano_codigo, status, trial_ate } }
import { chaveValida } from '../_shared/chave.ts'
import { bancoDeServico, responder, respostaOpcoes } from '../_shared/comum.ts'
import { registrarEmpresa, validarEmpresa } from '../_shared/registro.ts'

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return respostaOpcoes()
  if (req.method !== 'POST') return responder({ erro: 'Método não permitido.' }, 405)

  let corpo: Record<string, unknown>
  try {
    const lido = await req.json()
    if (typeof lido !== 'object' || lido === null || Array.isArray(lido)) throw new Error('forma')
    corpo = lido as Record<string, unknown>
  } catch {
    return responder({ erro: 'Dados inválidos.' }, 400)
  }
  if (typeof corpo.sistema !== 'string') return responder({ erro: 'Informe o sistema.' }, 400)

  const banco = bancoDeServico()
  const { data: sistema, error } = await banco.from('sistemas').select('id, chave_segredo, ativo').eq('codigo', corpo.sistema).maybeSingle()
  if (error) {
    console.error('sistemas:', error.message)
    return responder({ erro: 'Algo deu errado. Tente novamente.' }, 500)
  }
  // não revela se o sistema existe: sem sistema ou com chave errada é sempre 401
  if (!sistema || !sistema.ativo || !/^PORTAL_KEY_[A-Z0-9_]+$/.test(sistema.chave_segredo)) return responder({ erro: 'Chave inválida.' }, 401)
  const esperada = Deno.env.get(sistema.chave_segredo)
  if (!esperada || esperada.length < 24) return responder({ erro: 'O portal ainda não está configurado para este sistema.' }, 503)
  if (!chaveValida(req.headers.get('x-portal-key'), esperada)) return responder({ erro: 'Chave inválida.' }, 401)

  const validado = validarEmpresa(corpo.empresa)
  if (!validado.ok) return responder({ erro: validado.mensagem }, 400)

  try {
    const { criado } = await registrarEmpresa(banco, sistema.id, validado.empresa, 'cadastro')
    await banco.from('chamadas_aos_sistemas').insert({ sistema_id: sistema.id, acao: 'cadastro', pedido: { empresa_id: validado.empresa.empresa_id }, resposta: { criado }, ok: true })
    return responder({ ok: true, criado })
  } catch (e) {
    console.error('registrar-cliente:', (e as { message?: string }).message)
    await banco.from('chamadas_aos_sistemas').insert({ sistema_id: sistema.id, acao: 'cadastro', pedido: { empresa_id: validado.empresa.empresa_id }, resposta: null, ok: false })
    return responder({ erro: 'Algo deu errado. Tente novamente.' }, 500)
  }
})
