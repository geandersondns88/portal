// Envio da chave de licença pelo Gmail do administrador, via Google Apps Script (gratuito).
// Segredos desta função: GESTOR_EMAIL_URL (endereço do app da web do Apps Script) e GESTOR_EMAIL_SEGREDO (o mesmo valor do script).
// O script só envia se o segredo bater; ver supabase/email/Codigo.gs.
export type ResultadoEmail = { enviado: boolean; motivo?: string }

export async function enviarChave(p: { para: string | null; chave: string; cliente: string; plano: string | null; computadores: number | null }): Promise<ResultadoEmail> {
  const url = Deno.env.get('GESTOR_EMAIL_URL')
  const segredo = Deno.env.get('GESTOR_EMAIL_SEGREDO')
  if (!url || !segredo) return { enviado: false, motivo: 'O envio de e-mail ainda não foi configurado no portal (segredos GESTOR_EMAIL_URL e GESTOR_EMAIL_SEGREDO).' }
  if (!/^https:\/\/script\.google\.com\/macros\/s\/[A-Za-z0-9_-]+\/exec$/.test(url)) return { enviado: false, motivo: 'O endereço do envio de e-mail (GESTOR_EMAIL_URL) é inválido.' }
  if (!p.para || !/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(p.para)) return { enviado: false, motivo: 'Esta empresa não tem um e-mail válido cadastrado.' }
  try {
    const r = await fetch(url, {
      method: 'POST', headers: { 'Content-Type': 'application/json' }, redirect: 'follow', signal: AbortSignal.timeout(25000),
      body: JSON.stringify({ segredo, para: p.para, chave: p.chave, cliente: p.cliente, plano: p.plano, computadores: p.computadores }),
    })
    const corpo = await r.json().catch(() => null)
    if (r.ok && corpo?.ok === true) return { enviado: true }
    return { enviado: false, motivo: typeof corpo?.erro === 'string' ? corpo.erro : `O serviço de e-mail respondeu com erro (HTTP ${r.status}).` }
  } catch (e) {
    console.error('email:', (e as Error).message)
    return { enviado: false, motivo: 'Não foi possível falar com o serviço de e-mail.' }
  }
}
