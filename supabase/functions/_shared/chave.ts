/** A chave do sistema tem de existir (segredo), ter 24+ caracteres e ser igual à recebida; a comparação não vaza onde diferem. */
export function chaveValida(recebida: string | null | undefined, esperada: string | null | undefined): boolean {
  if (!esperada || esperada.length < 24 || !recebida) return false
  const a = new TextEncoder().encode(recebida)
  const b = new TextEncoder().encode(esperada)
  let diferenca = a.length ^ b.length
  const n = Math.max(a.length, b.length)
  for (let i = 0; i < n; i++) diferenca |= (a[i] ?? 0) ^ (b[i] ?? 0)
  return diferenca === 0
}
