// Utilidades das funções do portal: CORS, resposta JSON e conferência de que quem chama é um administrador.
import { createClient, type SupabaseClient } from 'npm:@supabase/supabase-js@2'

export const cabecalhosCors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
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
