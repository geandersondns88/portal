-- Portal central: quem pode operar (administradores) e a configuração do Mercado Pago.
-- Só as Edge Functions do portal (chave de serviço) leem e gravam estas tabelas; o navegador nunca as acessa direto.

create table public.administradores (
  user_id uuid primary key references auth.users(id) on delete cascade,
  email text not null,
  created_at timestamptz not null default now()
);

-- Uma única linha (id = true): os dados da conta Mercado Pago. O access_token NUNCA volta para a tela (só os 4 últimos caracteres).
create table public.config_mercadopago (
  id boolean primary key default true check (id),
  ambiente text not null default 'teste' check (ambiente in ('teste', 'producao')),
  public_key text,
  access_token text,
  webhook_secret text,
  url_notificacao text,
  atualizado_em timestamptz not null default now(),
  atualizado_por uuid references auth.users(id) on delete set null
);

alter table public.administradores enable row level security;
alter table public.config_mercadopago enable row level security;
revoke all on public.administradores, public.config_mercadopago from anon, authenticated;
