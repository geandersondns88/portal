// API de licença que o aplicativo Gestor+ chama (pública: verify_jwt = false; a chave de licença e o limite por IP são a proteção).
// POST JSON { acao, ... }:
//   ativar      { chave, maquina, nome, versao }   → { ok, licenca, token }
//   validar     { chave, maquina, versao }         → { ok, licenca, token }
//   solicitar   { cliente, cnpj, email, telefone, maquina } → { ok, email }  (pedido de licença: vira empresa "aguardando" no portal)
//   atualizacao { chave, maquina }                 → { ok, versao?, url? }
//   recuperar   { chave, maquina, codigo, consumir } → { ok, codigo }
//   chave_publica                                  → { ok, publica } (SPKI em base64, a que vai embutida no app)
// Erros: { erro } com o status HTTP (400 dados, 403/404 recusa definitiva, 409 conflito, 429 muitas tentativas).
import { assinar, parDeChaves } from '../_shared/assinatura.ts'
import { bancoDeServico, lerCorpo, respostaDoErro, respostaOpcoes, responder, rpc, texto } from '../_shared/comum.ts'
import { idDoSistema, registrarEmpresa, validarEmpresa } from '../_shared/registro.ts'

const TOLERANCIA_OFFLINE_DIAS = 30
// [chamadas, minutos] por IP
const LIMITES: Record<string, [number, number]> = { ativar: [30, 15], validar: [200, 15], solicitar: [5, 60], atualizacao: [100, 15], recuperar: [15, 15] }

const ipDe = (req: Request) => req.headers.get('cf-connecting-ip') ?? req.headers.get('x-forwarded-for')?.split(',')[0].trim() ?? 'desconhecido'

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return respostaOpcoes()
  if (req.method !== 'POST') return responder({ erro: 'Método não permitido.' }, 405)
  const c = await lerCorpo(req)
  if (!c || typeof c.acao !== 'string') return responder({ erro: 'Dados inválidos.' }, 400)
  const banco = bancoDeServico()
  try {
    if (c.acao === 'chave_publica') return responder({ ok: true, publica: (await parDeChaves(banco)).publica })
    const limite = LIMITES[c.acao]
    if (!limite) return responder({ erro: 'Ação inválida.' }, 400)
    await rpc(banco, 'gestor_app_limitar', { p_ip: ipDe(req), p_tipo: c.acao, p_max: limite[0], p_minutos: limite[1] })

    const chave = texto(c.chave, 40).toUpperCase().replace(/\s+/g, '')
    const maquina = texto(c.maquina, 64)
    const versao = texto(c.versao, 20) || null
    const comToken = async (licenca: Record<string, unknown>) => {
      const agora = Date.now()
      const conteudo = { ...licenca, emitido_em: new Date(agora).toISOString(), valido_ate: new Date(agora + TOLERANCIA_OFFLINE_DIAS * 864e5).toISOString() }
      return responder({ ok: true, licenca: conteudo, token: await assinar(banco, conteudo) })
    }

    switch (c.acao) {
      case 'ativar': return comToken(await rpc(banco, 'gestor_app_ativar', { p_chave: chave, p_maquina: maquina, p_nome: texto(c.nome, 80) || null, p_versao: versao }))
      case 'validar': return comToken(await rpc(banco, 'gestor_app_validar', { p_chave: chave, p_maquina: maquina, p_versao: versao }))
      case 'solicitar': {
        const r = await rpc(banco, 'gestor_app_solicitar', {
          p_cliente: texto(c.cliente, 200), p_documento: texto(c.cnpj ?? c.documento, 30), p_email: texto(c.email, 200), p_telefone: texto(c.telefone, 40) || null, p_maquina: maquina,
        })
        // avisa o portal (cliente e assinatura); se falhar, o pedido já está guardado e o "Sincronizar" do portal recupera
        try {
          const v = validarEmpresa(r)
          if (v.ok) await registrarEmpresa(banco, await idDoSistema(banco), v.empresa, 'cadastro')
        } catch (e) { console.error('registrar no portal:', (e as Error).message) }
        return responder({ ok: true, email: r.email })
      }
      case 'atualizacao': return responder({ ok: true, ...(await rpc(banco, 'gestor_app_atualizacao', { p_chave: chave, p_maquina: maquina })) })
      case 'recuperar': return responder({ ok: true, ...(await rpc(banco, 'gestor_app_recuperar', { p_chave: chave, p_maquina: maquina, p_codigo: texto(c.codigo, 40), p_consumir: c.consumir === true })) })
    }
    return responder({ erro: 'Ação inválida.' }, 400)
  } catch (e) {
    return respostaDoErro(e)
  }
})
