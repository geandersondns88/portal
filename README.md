# Portal central de assinaturas

Portal que controla as assinaturas de vários sistemas (começando pelo **Transporte**) e guarda a configuração do Mercado Pago.
Roda em um projeto Supabase próprio ("Portal", ref `vzoyugnoywtgnvabatrw`); cada sistema só expõe uma API de assinaturas
(contrato do Transporte em [`docs/api-transporte.md`](docs/api-transporte.md)).

## Estrutura

- `supabase/migrations/`: SQL do projeto Portal (001 = sistemas, clientes, assinaturas, cobranças e registro de chamadas; 002 = administradores e Mercado Pago; 003 = ícone, situação da assinatura e documento único).
- `supabase/functions/`: Edge Functions do Portal
  - `chamar-sistema`: chama a API de assinaturas de um sistema em nome do administrador logado. A chave de cada sistema é um segredo
    `PORTAL_KEY_*` (o nome fica em `sistemas.chave_segredo`) e nunca vai para a tela.
  - `portal-geral`: lista os sistemas (com ícone), verifica a saúde das comunicações (geral ou de um sistema) e sincroniza os clientes de um sistema.
  - `registrar-cliente`: recebe o aviso de cadastro novo enviado pelo sistema (sem login; protegida pela chave do sistema).
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

As telas são **iguais para todos os sistemas**: nada é escrito por sistema na página, tudo vem da tabela `sistemas` (nome, ícone, URL da API, segredo).
- **Sistemas** (tela principal): uma caixa com ícone por sistema. Ao abrir, o sistema tem três áreas:
  - **Clientes**: lista com situação, plano, fim do teste e uso (busca, filtro, paginação). Ao tocar num cliente: ativar, suspender, cancelar, estender o teste, trocar o plano (lista de planos do sistema) e ver o histórico. "Sincronizar com o portal" recupera cadastros que não tenham chegado.
  - **Status dos serviços**: testa de verdade a comunicação do portal com aquele sistema e mostra as últimas chamadas (atualiza a cada 60 s).
  - **Planos de assinatura**: começa vazio; você cria os planos do sistema (nome, limites, preço, ativo). O plano interno `trial` e os desativados ficam escondidos (há "Mostrar desativados").
- **Mercado Pago** (tela separada, a mesma para todos): ambiente, public key, access token, segredo e URL do webhook.

Para incluir um sistema novo: cadastre-o em `sistemas` (código, nome, `icone` entre `caminhao`, `onibus`, `loja`, `pessoas`, `calendario` e `app`, URL da API e o nome do segredo `PORTAL_KEY_<SISTEMA>`), crie o segredo e ele aparece sozinho. O sistema precisa seguir o mesmo contrato de API (`docs/api-transporte.md`: listar, eventos, ativar, suspender, cancelar, estender_teste, trocar_plano, planos_listar, plano_salvar, plano_excluir) e avisar o portal quando alguém se cadastrar.

## Cadastro novo vira cliente do portal

Quando uma empresa se cadastra no sistema (teste grátis de 15 dias), o sistema chama `registrar-cliente` com a mesma chave (`x-portal-key`); o portal cria o cliente e a assinatura
(o mesmo CNPJ/CPF em sistemas diferentes é o mesmo cliente). Se o aviso se perder, **Clientes → Sincronizar com o portal** traz tudo de novo, sem duplicar.

## Publicar a página no Firebase Hosting

O workflow `.github/workflows/publicar.yml` publica `web/` no site `gdns88` (projeto `gdns88`) sozinho a cada mudança em `web/` na `main`, e também manualmente
(*Actions → Publicar portal no Firebase Hosting → Run workflow*; os campos **site** e **projeto** são opcionais). Usa o secret `FIREBASE_SERVICE_ACCOUNT` deste repositório
(Firebase Console → Configurações do projeto → Contas de serviço → Gerar nova chave privada). Endereço: `https://gdns88.web.app`.

## Funções do Supabase

As funções e migrations foram aplicadas no projeto Portal pelo painel/MCP do Supabase. Para reaplicar com a CLI: `supabase functions deploy chamar-sistema`,
`supabase functions deploy portal-geral` e `supabase functions deploy config-mercadopago` (com verificação de JWT ligada) e `supabase functions deploy registrar-cliente --no-verify-jwt`, e `supabase db push` ou colar as migrations no SQL Editor.

## Gestor+ (licença do aplicativo)

O Gestor+ é um aplicativo de computador (Electron) vendido por assinatura. A licença e a assinatura dele são controladas aqui; o aplicativo guarda os dados do cliente só no computador do cliente.

- **Banco:** esquema `gestor` (migration `004_gestor.sql`), isolado e sem acesso direto: só as Edge Functions, por funções SQL `public.gestor_*` (só o `service_role` executa).
- **`gestor-assinaturas`** (sem JWT, chave `PORTAL_KEY_GESTOR` no cabeçalho `x-portal-key`): o mesmo contrato dos outros sistemas, mais `licenca_ver`, `chave_gerar`, `chave_reenviar`, `chave_bloquear`, `chave_desbloquear`,
  `maquina_liberar`, `limite_definir`, `vencimento_definir`, `recuperacao_gerar` (a tela chama pelo `chamar-sistema`) e `atualizacao_publicar` e `importar` (só por script, com a chave).
- **`gestor-licenca`** (pública; limite de tentativas por IP): `ativar`, `validar`, `solicitar`, `atualizacao`, `recuperar` e `chave_publica`. Devolve a licença **assinada (Ed25519)**; o aplicativo confere com a chave pública embutida e funciona até 30 dias sem internet.
- **Regra de assinatura:** em dia → aviso nos 7 dias antes de vencer → carência de 7 dias depois do vencimento → **somente leitura**. Suspensa ou cancelada vai direto para somente leitura; cadastro novo fica "aguardando liberação" (leitura) até alguém liberar.
  O vencimento vem do fim do teste, das cobranças do portal (quando existirem) ou da data definida à mão (`vencimento_definir`; sem data o acesso não vence). Os 7 e 7 dias ficam em `gestor.config`.
- **Tela:** ao abrir uma empresa do Gestor+ aparece o painel de licença (situação, vencimento, chave, computadores ativados, limite e código de recuperação). Planos usam "máx. de computadores".
- **Instalador:** fica no site de Hosting `gestormais-gdns88` (mesmo projeto `gdns88`, separado deste site porque cada publicação substitui o site inteiro), publicado pelo `npm run publicar` do repositório do Gestor+.

Segredos (além de `PORTAL_KEY_TRANSPORTE`): `PORTAL_KEY_GESTOR` (24+ caracteres), `GESTOR_EMAIL_URL` e `GESTOR_EMAIL_SEGREDO` (envio da chave por e-mail via Google Apps Script).
