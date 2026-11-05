# Portal central de assinaturas

Portal que controla as assinaturas de vários sistemas (começando pelo **Transporte**) e guarda a configuração do Mercado Pago.
Roda em um projeto Supabase próprio ("Portal", ref `vzoyugnoywtgnvabatrw`); cada sistema só expõe uma API de assinaturas
(contrato do Transporte em [`docs/api-transporte.md`](docs/api-transporte.md)).

## Estrutura

- `supabase/migrations/`: SQL do projeto Portal (001 = sistemas, clientes, assinaturas, cobranças e registro de chamadas; 002 = administradores e Mercado Pago).
- `supabase/functions/`: Edge Functions do Portal
  - `chamar-sistema`: chama a API de assinaturas de um sistema em nome do administrador logado. A chave de cada sistema é um segredo
    `PORTAL_KEY_*` (o nome fica em `sistemas.chave_segredo`) e nunca vai para a tela.
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

## Publicar a página no Firebase Hosting

1. No Firebase Console, ative o Hosting e crie um site só para o portal (*Hosting → Add another site*), por exemplo `frotus88-portal`.
2. Neste repositório, em *Settings → Secrets and variables → Actions*, crie o **Secret** `FIREBASE_SERVICE_ACCOUNT` com o JSON da conta de serviço do projeto
   (papel *Firebase Hosting Admin*; pode ser o mesmo JSON que publica o Transporte, se o site ficar no mesmo projeto).
3. *Actions → Publicar portal no Firebase Hosting → Run workflow*, com o id do site no campo **site** (ou guarde-o na variável `FIREBASE_HOSTING_SITE`).

Depois disso, cada mudança em `web/` na `main` publica sozinha.

## Funções do Supabase

As funções e migrations foram aplicadas no projeto Portal pelo painel/MCP do Supabase. Para reaplicar com a CLI: `supabase functions deploy chamar-sistema` e
`supabase functions deploy config-mercadopago` (ambas com verificação de JWT ligada), e `supabase db push` ou colar as migrations no SQL Editor.
