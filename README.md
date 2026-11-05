# Portal central de assinaturas

Portal que controla as assinaturas de vários sistemas (começando pelo **Transporte**) e guarda a configuração do Mercado Pago.
Roda em um projeto Supabase próprio ("Portal", ref `vzoyugnoywtgnvabatrw`); cada sistema só expõe uma API de assinaturas
(contrato do Transporte em [`docs/api-transporte.md`](docs/api-transporte.md)).

## Estrutura

- `supabase/migrations/`: SQL do projeto Portal (001 = sistemas, clientes, assinaturas, cobranças e registro de chamadas; 002 = administradores e Mercado Pago).
- `supabase/functions/`: Edge Functions do Portal
  - `chamar-sistema`: chama a API de assinaturas de um sistema em nome do administrador logado. A chave de cada sistema é um segredo
    `PORTAL_KEY_*` (o nome fica em `sistemas.chave_segredo`) e nunca vai para a tela.
  - `portal-geral`: lista os sistemas e faz a verificação de saúde das comunicações.
  - `config-mercadopago`: lê, salva e testa as credenciais do Mercado Pago; o access token e o segredo do webhook nunca voltam para a tela (só os 4 últimos caracteres).
- `web/index.html`: página única (login + teste de conexão com os sistemas + Mercado Pago).
- `.github/workflows/publicar.yml`: publica `web/` no Firebase Hosting.
- `docs/api-transporte.md`: contrato da API de assinaturas do Transporte.

## Acesso

Só quem estiver na tabela `administradores`. Crie o usuário em *Authentication → Users* (Supabase do Portal, com "Auto Confirm User") e cadastre:

```sql
insert into public.administradores (user_id, email)
select id, email from auth.users where email = 'SEU_EMAIL';
```

As tabelas não têm acesso para o navegador (RLS sem política, `anon` e `authenticated` sem permissão): só as Edge Functions, com a chave de serviço, leem e gravam.

## Segredos (Supabase → Edge Functions → Secrets, no projeto Portal)

| Nome | Para quê |
|---|---|
| `PORTAL_KEY_TRANSPORTE` | Mesma chave do segredo `PORTAL_API_KEY` do projeto do Transporte |

Para cada novo sistema: cadastre-o em `sistemas` (código, nome, URL da API, nome do segredo `PORTAL_KEY_<SISTEMA>`), crie o segredo e acrescente o sistema na lista `SISTEMAS` de `web/index.html`.

## Telas

As telas são **iguais para todos os sistemas**: nada é escrito por sistema na página, tudo vem da tabela `sistemas`.
- **Clientes**: cada sistema aparece como um módulo; ao abrir, lista os clientes com situação, plano, fim do teste e uso (busca, filtro por situação, paginação). Ao tocar num cliente: ativar, suspender, cancelar, estender o teste, trocar o plano e ver o histórico.
- **Saúde**: testa de verdade o banco do portal, a API de cada sistema e o Mercado Pago (operacional, com falha ou não configurado) e mostra as últimas chamadas. Atualiza a cada 60 segundos.
- **Mercado Pago**: ambiente, public key, access token, segredo e URL do webhook.

Para incluir um sistema novo: cadastre-o em `sistemas`, crie o segredo `PORTAL_KEY_<SISTEMA>` e pronto: ele aparece em Clientes e em Saúde. O sistema precisa seguir o mesmo contrato de API (`docs/api-transporte.md`).

## Publicar a página no Firebase Hosting

O workflow `.github/workflows/publicar.yml` publica `web/` no site `gdns88` (projeto `gdns88`) sozinho a cada mudança em `web/` na `main`, e também manualmente
(*Actions → Publicar portal no Firebase Hosting → Run workflow*; os campos **site** e **projeto** são opcionais). Usa o secret `FIREBASE_SERVICE_ACCOUNT` deste repositório
(Firebase Console → Configurações do projeto → Contas de serviço → Gerar nova chave privada). Endereço: `https://gdns88.web.app`.

## Funções do Supabase

As funções e migrations foram aplicadas no projeto Portal pelo painel/MCP do Supabase. Para reaplicar com a CLI: `supabase functions deploy chamar-sistema`,
`supabase functions deploy portal-geral` e `supabase functions deploy config-mercadopago` (todas com verificação de JWT ligada), e `supabase db push` ou colar as migrations no SQL Editor.
