// Utilidades das funções do portal: CORS, resposta JSON e conferência de que quem chama é um administrador.
import { createClient, type SupabaseClient } from 'npm:@supabase/supabase-js@2'

export const cabecalhosCors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-portal-key',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}

export function responder(corpo: unknown, status = 200): Response {
  return new Response(JSON.stringify(corpo), { status, headers: { ...cabecalhosCors, 'Content-Type': 'application/json' } })
}

export const respostaOpcoes = () => new Response('ok', { headers: cabecalhosCors })

export function bancoDeServico(): SupabaseClient {
  return createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false, autoRefreshToken: false } })
}

/** Devolve o id do administrador logado, ou uma resposta de erro pronta (401 sem login, 403 se não for administrador). */
export async function exigirAdministrador(req: Request, banco: SupabaseClient): Promise<{ userId: string } | Response> {
  const token = (req.headers.get('Authorization') ?? '').replace(/^Bearer\s+/i, '')
  if (!token) return responder({ erro: 'Entre para continuar.' }, 401)
  const { data, error } = await banco.auth.getUser(token)
  if (error || !data.user) return responder({ erro: 'Sessão inválida. Entre de novo.' }, 401)
  const { data: adm, error: erroAdm } = await banco.from('administradores').select('user_id').eq('user_id', data.user.id).maybeSingle()
  if (erroAdm) {
    console.error('administradores:', erroAdm.message)
    return responder({ erro: 'Algo deu errado. Tente novamente.' }, 500)
  }
  if (!adm) return responder({ erro: 'Sem permissão.' }, 403)
  return { userId: data.user.id }
}

// ---------- usado pelas funções do Gestor+ (gestor-assinaturas e gestor-licenca) ----------

/** Erro com o status HTTP e a mensagem (em português) que vão para quem chamou. */
export class ErroHttp extends Error {
  constructor(mensagem: string, public status: number) { super(mensagem) }
}

/** Chama uma função SQL `public.gestor_*` (só o service_role executa). */
export async function rpc<T = Record<string, unknown>>(banco: SupabaseClient, nome: string, args: Record<string, unknown> = {}): Promise<T> {
  const { data, error } = await banco.rpc(nome, args)
  if (error) throw error
  return data as T
}

/**
 * As funções SQL recusam com `raise exception` + hint = status HTTP (ex.: 409) e a mensagem já em português: isso vai para o cliente.
 * Qualquer outro erro do banco é registrado no log e vira uma mensagem genérica (sem vazar detalhe).
 */
export function respostaDoErro(e: unknown): Response {
  if (e instanceof ErroHttp) return responder({ erro: e.message }, e.status)
  const x = e as { code?: string; hint?: string; message?: string }
  if (x?.code === 'P0001' && /^[1-5]\d\d$/.test(x.hint ?? '')) return responder({ erro: x.message }, Number(x.hint))
  console.error('gestor:', x?.code, x?.message)
  return responder({ erro: 'Algo deu errado. Tente novamente.' }, 500)
}

export async function lerCorpo(req: Request): Promise<Record<string, unknown> | null> {
  try {
    const lido = await req.json()
    return typeof lido === 'object' && lido !== null && !Array.isArray(lido) ? (lido as Record<string, unknown>) : null
  } catch {
    return null
  }
}

export const objeto = (v: unknown): Record<string, unknown> => (typeof v === 'object' && v !== null && !Array.isArray(v) ? (v as Record<string, unknown>) : {})
export const texto = (v: unknown, max: number): string => (typeof v === 'string' ? v.trim().slice(0, max) : '')
export const inteiro = (v: unknown, padrao: number): number => (Number.isFinite(Number(v)) && v !== null && v !== '' ? Math.trunc(Number(v)) : padrao)
