# API do portal de assinaturas

Este sistema (Transporte) **não** tem portal, tela de cobrança nem tabela de clientes do portal: ele só expõe esta API. O portal é um projeto
à parte, que centraliza as assinaturas de vários sistemas. Para cada sistema o portal guarda a URL da API e a chave
(o código do portal está no repositório `portal`); os outros sistemas devem seguir o mesmo contrato abaixo,
cada um com a sua própria chave `PORTAL_API_KEY`.

Estrutura para o **portal externo** (com Supabase e tela próprios) controlar as assinaturas das empresas deste sistema.
O portal **não** é um usuário do sistema: ele chama, de servidor para servidor, a Edge Function `portal-assinaturas` com uma chave secreta.
Nada aqui vai para o navegador: a chave fica só no servidor do portal.

## Configuração (uma vez)

1. A migration 45 e a função `portal-assinaturas` já ficam publicadas no projeto.
2. Em *Supabase → Edge Functions → Secrets*, crie o segredo **`PORTAL_API_KEY`** com um valor aleatório de **24 caracteres ou mais**
   (ex.: gere com `openssl rand -hex 32`). Sem o segredo (ou com menos de 24 caracteres) a função responde `503`.
3. Guarde a mesma chave no servidor do portal (variável de ambiente do portal). Nunca no código nem no navegador. Para trocar a
   chave, crie o segredo de novo com outro valor e atualize o portal.

## Chamada

- **URL:** `https://tindhrtijvqkxdeiqzil.supabase.co/functions/v1/portal-assinaturas`
- **Método:** `POST`, corpo JSON, cabeçalhos `Content-Type: application/json` e `x-portal-key: <PORTAL_API_KEY>`.
- A função não exige login (`verify_jwt = false`); quem manda é a chave.

```bash
curl -X POST "$URL" -H "x-portal-key: $PORTAL_API_KEY" -H "Content-Type: application/json" \
  -d '{"acao":"listar","status":"trial","limite":20}'
```

## Ações

| `acao` | Campos | O que faz |
|---|---|---|
| `listar` | `busca?` (nome, fantasia ou CNPJ/CPF, até 100), `status?` (`trial`, `ativa`, `suspensa`, `cancelada`), `limite?` (1–200, padrão 50), `deslocamento?` | Lista as empresas, mais novas primeiro |
| `eventos` | `empresa_id`, `limite?` (1–200, padrão 50) | Histórico de mudanças de assinatura da empresa |
| `ativar` | `empresa_id`, `dados.motivo?` | Status vira `ativa` (assinatura paga) |
| `suspender` | `empresa_id`, `dados.motivo?` | Status vira `suspensa` (o acesso é bloqueado) |
| `cancelar` | `empresa_id`, `dados.motivo?` | Status vira `cancelada` |
| `estender_teste` | `empresa_id`, `dados.dias` (1–365), `dados.motivo?` | Status `trial` e `trial_ate` = maior entre o atual e hoje, + dias |
| `trocar_plano` | `empresa_id`, `dados.plano_codigo`, `dados.motivo?` | Muda o plano (o código precisa existir em `planos`) |

`dados.motivo` tem até 300 caracteres e fica guardado no evento.

### Respostas

```jsonc
// listar
{ "ok": true, "total": 12, "empresas": [
  { "empresa_id": "…", "nome": "…", "nome_fantasia": "…", "documento": "…", "email": "…", "telefone": "…",
    "plano_codigo": "basico", "status": "trial", "trial_ate": "2026-11-20", "liberada": true,
    "criada_em": "2026-11-01T…", "usuarios": 3, "veiculos": 5 } ] }

// eventos
{ "ok": true, "eventos": [ { "id": "…", "acao": "suspender", "anterior": { "status": "ativa", … }, "depois": { "status": "suspensa", … }, "detalhes": { "motivo": "…" }, "origem": "portal", "created_at": "…" } ] }

// ativar / suspender / cancelar / estender_teste / trocar_plano
{ "ok": true, "assinatura": { "status": "ativa", "plano_codigo": "basico", "trial_ate": null } }
```

`total` é o número de empresas que passam no filtro (para paginar com `limite` e `deslocamento`).
`liberada` diz se a empresa pode usar o sistema agora (assinatura ativa ou teste dentro do prazo).

### Erros

| Status | Quando | Corpo |
|---|---|---|
| 400 | Pedido inválido (ação, `empresa_id`, `dias`, `plano_codigo`…) | `{ "erro": "mensagem em português" }` |
| 401 | Chave ausente ou errada | `{ "erro": "Chave inválida." }` |
| 404 | Empresa não existe | `{ "erro": "Empresa não encontrada." }` |
| 405 | Método diferente de `POST` | `{ "erro": "Método não permitido." }` |
| 503 | `PORTAL_API_KEY` não configurada | `{ "erro": "O portal ainda não está configurado." }` |
| 500 | Falha inesperada | `{ "erro": "Algo deu errado. Tente novamente." }` |

## Segurança

- A chave é conferida em tempo constante e precisa ter ao menos 24 caracteres.
- As funções do banco (`portal_listar_empresas`, `portal_alterar_assinatura`, `portal_eventos`) só podem ser executadas pela
  `service_role`; usuários do sistema (inclusive admin de empresa) não conseguem chamá-las.
- A tabela `assinatura_eventos` não tem acesso para usuários do sistema; só a API do portal lê e grava nela.
- Cada alteração grava um evento com o estado anterior e o novo, o motivo e a origem (`portal`).
- A API **não** devolve dados operacionais das empresas (clientes, viagens, valores): só cadastro básico e uso (nº de usuários e veículos).
- Chame a API apenas do servidor do portal. Considere limitar por IP e trocar a chave periodicamente.

## Pagamento

A cobrança (Pix, cartão, boleto) é do portal: quando o pagamento confirmar, o portal chama `ativar`; se atrasar, `suspender`.
O sistema só guarda o resultado (status, plano, fim do teste).
