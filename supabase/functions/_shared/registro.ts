// Cliente e assinatura no portal: criados quando uma empresa se cadastra num sistema (aviso do sistema) ou ao sincronizar.
// O mesmo CNPJ/CPF em sistemas diferentes é o mesmo cliente; a assinatura é uma por (sistema, empresa).
import type { SupabaseClient } from 'npm:@supabase/supabase-js@2'

export type EmpresaDoSistema = {
  empresa_id: string
  nome: string
  nome_fantasia: string | null
  documento: string | null
  email: string | null
  telefone: string | null
  plano_codigo: string
  status: string
  trial_ate: string | null
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
const SITUACOES = ['trial', 'ativa', 'suspensa', 'cancelada']

const textoOuNulo = (v: unknown, max: number): string | null | undefined => {
  if (v === undefined || v === null || v === '') return null
  return typeof v === 'string' && v.length <= max ? v.trim() || null : undefined
}

/** Confere o formato do que o sistema mandou; nada daqui é confiado além disso. */
export function validarEmpresa(v: unknown): { ok: true; empresa: EmpresaDoSistema } | { ok: false; mensagem: string } {
  if (typeof v !== 'object' || v === null || Array.isArray(v)) return { ok: false, mensagem: 'Dados inválidos.' }
  const c = v as Record<string, unknown>
  if (typeof c.empresa_id !== 'string' || !UUID.test(c.empresa_id)) return { ok: false, mensagem: 'Empresa inválida.' }
  const nome = textoOuNulo(c.nome, 200)
  if (!nome) return { ok: false, mensagem: 'Informe o nome da empresa.' }
  const fantasia = textoOuNulo(c.nome_fantasia, 200)
  const documento = textoOuNulo(c.documento, 30)
  const email = textoOuNulo(c.email, 200)
  const telefone = textoOuNulo(c.telefone, 40)
  if ([fantasia, documento, email, telefone].some((x) => x === undefined)) return { ok: false, mensagem: 'Dados inválidos.' }
  if (typeof c.plano_codigo !== 'string' || c.plano_codigo === '' || c.plano_codigo.length > 40) return { ok: false, mensagem: 'Plano inválido.' }
  if (typeof c.status !== 'string' || !SITUACOES.includes(c.status)) return { ok: false, mensagem: 'Situação inválida.' }
  if (c.trial_ate !== null && c.trial_ate !== undefined && (typeof c.trial_ate !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(c.trial_ate))) return { ok: false, mensagem: 'Data do teste inválida.' }
  return {
    ok: true,
    empresa: {
      empresa_id: c.empresa_id.toLowerCase(), nome, nome_fantasia: fantasia ?? null, documento: documento ?? null, email: email ?? null, telefone: telefone ?? null,
      plano_codigo: c.plano_codigo, status: c.status, trial_ate: (c.trial_ate as string | null | undefined) ?? null,
    },
  }
}

/** Cria (ou atualiza) o cliente e a assinatura. Devolve se a assinatura é nova. Idempotente: chamar duas vezes não duplica nada. */
export async function registrarEmpresa(banco: SupabaseClient, sistemaId: string, e: EmpresaDoSistema, origem: 'cadastro' | 'sincronizacao'): Promise<{ criado: boolean }> {
  const documento = (e.documento ?? '').replace(/\D/g, '') || null

  const procurarCliente = async (): Promise<string | null> => {
    if (!documento) return null
    const { data, error } = await banco.from('clientes_portal').select('id, email, telefone').eq('documento', documento).maybeSingle()
    if (error) throw error
    if (data) {
      // cliente que já existe: só completa o que estiver vazio (e-mail e telefone), sem sobrescrever o que alguém editou
      const completar: Record<string, string> = {}
      if (!data.email && e.email) completar.email = e.email
      if (!data.telefone && e.telefone) completar.telefone = e.telefone
      if (Object.keys(completar).length > 0) {
        const { error: erroAtualizar } = await banco.from('clientes_portal').update(completar).eq('id', data.id)
        if (erroAtualizar) throw erroAtualizar
      }
    }
    return data?.id ?? null
  }

  let clienteId = await procurarCliente()
  if (!clienteId) {
    const { data, error } = await banco.from('clientes_portal').insert({ nome: e.nome_fantasia || e.nome, documento, email: e.email, telefone: e.telefone }).select('id').single()
    if (error) {
      if (error.code === '23505') clienteId = await procurarCliente() // dois avisos ao mesmo tempo: o outro criou primeiro
      if (!clienteId) throw error
    } else {
      clienteId = data.id
    }
  }

  const { data: existente, error: erroBusca } = await banco.from('assinaturas').select('id').eq('sistema_id', sistemaId).eq('empresa_id', e.empresa_id).maybeSingle()
  if (erroBusca) throw erroBusca
  const campos = { cliente_id: clienteId, plano_codigo: e.plano_codigo, status: e.status, trial_ate: e.trial_ate, sincronizada_em: new Date().toISOString() }
  if (existente) {
    const { error } = await banco.from('assinaturas').update(campos).eq('id', existente.id)
    if (error) throw error
    return { criado: false }
  }
  const { error } = await banco.from('assinaturas').insert({ ...campos, sistema_id: sistemaId, empresa_id: e.empresa_id, origem })
  if (error) {
    if (error.code === '23505') return { criado: false } // o aviso e a sincronização rodaram juntos
    throw error
  }
  return { criado: true }
}
