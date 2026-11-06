// Assinatura da licença (Ed25519). O app guarda a licença com o token assinado e confere a assinatura com a chave pública embutida nele:
// sem acesso ao portal ninguém consegue fabricar nem editar uma licença.
// O par de chaves nasce na primeira chamada e fica em gestor.config ('ed25519_par'), legível só pelo service_role.
import type { SupabaseClient } from 'npm:@supabase/supabase-js@2'
import { rpc } from './comum.ts'

const b64 = (b: ArrayBuffer | Uint8Array) => btoa(String.fromCharCode(...new Uint8Array(b)))
const b64url = (b: ArrayBuffer | Uint8Array) => b64(b).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '')
const deB64 = (s: string) => Uint8Array.from(atob(s), (c) => c.charCodeAt(0))

let guardado: { privada: CryptoKey; publica: string } | null = null

export async function parDeChaves(banco: SupabaseClient): Promise<{ privada: CryptoKey; publica: string }> {
  if (guardado) return guardado
  let json = await rpc<string | null>(banco, 'gestor_config_obter', { p_chave: 'ed25519_par' })
  if (!json) {
    const k = (await crypto.subtle.generateKey('Ed25519', true, ['sign', 'verify'])) as CryptoKeyPair
    const novo = JSON.stringify({ privada: b64(await crypto.subtle.exportKey('pkcs8', k.privateKey)), publica: b64(await crypto.subtle.exportKey('spki', k.publicKey)) })
    // grava só se ainda não existir; se duas chamadas nascerem juntas, as duas usam o par que ficou gravado
    json = await rpc<string>(banco, 'gestor_config_criar', { p_chave: 'ed25519_par', p_valor: novo })
  }
  const { privada, publica } = JSON.parse(json) as { privada: string; publica: string }
  guardado = { privada: await crypto.subtle.importKey('pkcs8', deB64(privada), 'Ed25519', false, ['sign']), publica }
  return guardado
}

/** Token = base64url(JSON da licença) + '.' + base64url(assinatura sobre o texto da primeira parte). */
export async function assinar(banco: SupabaseClient, conteudo: Record<string, unknown>): Promise<string> {
  const { privada } = await parDeChaves(banco)
  const corpo = b64url(new TextEncoder().encode(JSON.stringify(conteudo)))
  const assinatura = await crypto.subtle.sign('Ed25519', privada, new TextEncoder().encode(corpo))
  return `${corpo}.${b64url(assinatura)}`
}
