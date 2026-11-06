// API de assinaturas do Gestor+, chamada pelo portal (funções chamar-sistema e portal-geral).
// Sem login de usuário (verify_jwt = false): quem chama prova com a chave do sistema (segredo PORTAL_KEY_GESTOR) no cabeçalho x-portal-key.
// Contrato do portal: POST JSON { acao, empresa_id?, dados?, ... } → { ok: true, ... } ou { erro } com o status HTTP.
// Ações do contrato: listar, eventos, ativar, suspender, cancelar, estender_teste, trocar_plano, planos_listar, plano_salvar, plano_excluir.
// Ações do Gestor+ (licença do aplicativo): licenca_ver, chave_gerar, chave_reenviar, chave_bloquear, chave_desbloquear, maquina_liberar,
//   limite_definir, vencimento_definir, recuperacao_gerar, atualizacao_publicar, importar.
import type { SupabaseClient } from 'npm:@supabase/supabase-js@2'
import { chaveValida } from '../_shared/chave.ts'
import { bancoDeServico, ErroHttp, inteiro, lerCorpo, objeto, respostaDoErro, respostaOpcoes, responder, rpc, texto } from '../_shared/comum.ts'
import { enviarChave } from '../_shared/email.ts'
import { idDoSistema, registrarEmpresa, validarEmpresa } from '../_shared/registro.ts'

type Dados = Record<string, unknown>
type Licenca = {
  empresa: { empresa_id: string; nome: string; nome_fantasia: string | null; email: string | null; plano_nome: string | null }
  licenca: { chave: string; status: string } | null
  limite_computadores: number | null
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

async function tratar(banco: SupabaseClient, c: Dados): Promise<Response> {
  const acao = c.acao
  const dados = objeto(c.dados)
  const empresa = (): string => {
    if (typeof c.empresa_id !== 'string' || !UUID.test(c.empresa_id)) throw new ErroHttp('Empresa inválida.', 400)
    return c.empresa_id.toLowerCase()
  }
  const enviarPorEmail = async (id: string, lic: Licenca) => {
    const r = await enviarChave({ para: lic.empresa.email, chave: lic.licenca!.chave, cliente: lic.empresa.nome_fantasia || lic.empresa.nome, plano: lic.empresa.plano_nome, computadores: lic.limite_computadores })
    if (r.enviado) await rpc(banco, 'gestor_portal_marcar_email', { p_empresa: id })
    return r
  }

  switch (acao) {
    // ----- contrato do portal -----
    case 'listar': {
      const d = await rpc(banco, 'gestor_portal_listar_empresas', { p_busca: texto(c.busca, 100) || null, p_status: texto(c.status, 20) || null, p_limite: inteiro(c.limite, 25), p_deslocamento: inteiro(c.deslocamento, 0) })
      return responder({ ok: true, ...d })
    }
    case 'eventos': {
      const d = await rpc(banco, 'gestor_portal_eventos', { p_empresa: empresa(), p_limite: inteiro(c.limite, 10) })
      return responder({ ok: true, ...d })
    }
    case 'ativar': case 'suspender': case 'cancelar': case 'estender_teste': case 'trocar_plano': {
      const d = await rpc(banco, 'gestor_portal_alterar_assinatura', { p_empresa: empresa(), p_acao: acao, p_dados: dados })
      return responder({ ok: true, assinatura: d })
    }
    case 'planos_listar': return responder({ ok: true, ...(await rpc(banco, 'gestor_portal_listar_planos')) })
    case 'plano_salvar': return responder({ ok: true, ...(await rpc(banco, 'gestor_portal_salvar_plano', { p_dados: dados })) })
    case 'plano_excluir': return responder({ ok: true, ...(await rpc(banco, 'gestor_portal_excluir_plano', { p_codigo: texto(c.codigo, 40) })) })

    // ----- licença do aplicativo -----
    case 'licenca_ver': return responder({ ok: true, ...(await rpc(banco, 'gestor_portal_licenca', { p_empresa: empresa() })) })
    case 'chave_gerar': case 'chave_reenviar': {
      const id = empresa()
      const gerada = acao === 'chave_gerar' ? await rpc<{ nova: boolean }>(banco, 'gestor_portal_gerar_chave', { p_empresa: id, p_substituir: dados.substituir === true }) : null
      const lic = await rpc<Licenca>(banco, 'gestor_portal_licenca', { p_empresa: id })
      if (!lic.licenca) throw new ErroHttp('Esta empresa ainda não tem chave.', 404)
      const email = acao === 'chave_reenviar' || dados.enviar === true ? await enviarPorEmail(id, lic) : { enviado: false, motivo: 'Envio não solicitado.' }
      return responder({ ok: true, chave: lic.licenca.chave, nova: gerada?.nova ?? false, status: lic.licenca.status, email })
    }
    case 'chave_bloquear': case 'chave_desbloquear':
      return responder({ ok: true, ...(await rpc(banco, 'gestor_portal_bloquear_chave', { p_empresa: empresa(), p_bloquear: acao === 'chave_bloquear', p_motivo: texto(dados.motivo, 300) || null })) })
    case 'maquina_liberar':
      return responder({ ok: true, ...(await rpc(banco, 'gestor_portal_liberar_maquina', { p_empresa: empresa(), p_maquina: texto(dados.maquina, 64) })) })
    case 'limite_definir': {
      const bruto = dados.limite
      const limite = bruto === null || bruto === undefined || bruto === '' ? null : Number(bruto)
      if (limite !== null && !Number.isInteger(limite)) throw new ErroHttp('O limite deve ser um número inteiro (ou vazio para seguir o plano).', 400)
      return responder({ ok: true, ...(await rpc(banco, 'gestor_portal_definir_limite', { p_empresa: empresa(), p_limite: limite })) })
    }
    case 'vencimento_definir': return responder({ ok: true, assinatura: await rpc(banco, 'gestor_portal_definir_vencimento', { p_empresa: empresa(), p_dados: dados }) })
    case 'recuperacao_gerar': return responder({ ok: true, ...(await rpc(banco, 'gestor_portal_gerar_recuperacao', { p_empresa: empresa() })) })
    case 'atualizacao_publicar': return responder({ ok: true, ...(await rpc(banco, 'gestor_portal_publicar_atualizacao', { p_versao: texto(dados.versao, 20), p_url: texto(dados.url, 500) })) })
    case 'importar': {
      // cliente que já existia: entra com a mesma chave e os mesmos computadores; o portal ganha o cliente e a assinatura
      const r = await rpc<{ empresa_id: string }>(banco, 'gestor_portal_importar', { p_dados: dados })
      const lic = await rpc<Licenca & { empresa: unknown }>(banco, 'gestor_portal_licenca', { p_empresa: r.empresa_id })
      const v = validarEmpresa(lic.empresa)
      let portal = 'ok'
      if (v.ok) await registrarEmpresa(banco, await idDoSistema(banco), v.empresa, 'sincronizacao')
      else portal = v.mensagem
      return responder({ ok: true, ...r, portal })
    }
    default: return responder({ erro: 'Ação inválida.' }, 400)
  }
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return respostaOpcoes()
  if (req.method !== 'POST') return responder({ erro: 'Método não permitido.' }, 405)
  const esperada = Deno.env.get('PORTAL_KEY_GESTOR')
  if (!esperada || esperada.length < 24) return responder({ erro: 'O portal ainda não está configurado para este sistema.' }, 503)
  if (!chaveValida(req.headers.get('x-portal-key'), esperada)) return responder({ erro: 'Chave inválida.' }, 401)
  const corpo = await lerCorpo(req)
  if (!corpo) return responder({ erro: 'Dados inválidos.' }, 400)
  try {
    return await tratar(bancoDeServico(), corpo)
  } catch (e) {
    return respostaDoErro(e)
  }
})
