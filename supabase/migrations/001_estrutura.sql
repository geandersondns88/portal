-- Portal central de assinaturas (projeto Supabase "Portal"): vários sistemas, clientes, assinaturas por sistema, cobranças e registro de chamadas.
-- A SITUAÇÃO da assinatura (ativa, suspensa, teste…) mora em cada sistema: o portal a altera pela API do sistema (ver docs/api-transporte.md).
-- A chave de API de cada sistema NÃO fica nestas tabelas: fica em segredos das Edge Functions (nome em sistemas.chave_segredo, padrão PORTAL_KEY_*).

create table public.sistemas (
  id uuid primary key default gen_random_uuid(),
  codigo text not null unique,
  nome text not null,
  url_api text not null,
  chave_segredo text not null,
  ativo boolean not null default true,
  created_at timestamptz not null default now()
);

create table public.clientes_portal (
  id uuid primary key default gen_random_uuid(),
  nome text not null,
  documento text,
  email text,
  telefone text,
  observacoes text,
  created_at timestamptz not null default now()
);

create table public.assinaturas (
  id uuid primary key default gen_random_uuid(),
  cliente_id uuid not null references public.clientes_portal(id) on delete restrict,
  sistema_id uuid not null references public.sistemas(id) on delete restrict,
  empresa_id uuid not null,
  plano_codigo text not null,
  valor_mensal numeric(12,2) not null default 0 check (valor_mensal >= 0),
  dia_vencimento int check (dia_vencimento between 1 and 28),
  ativo boolean not null default true,
  created_at timestamptz not null default now(),
  unique (sistema_id, empresa_id)
);

create table public.cobrancas (
  id uuid primary key default gen_random_uuid(),
  assinatura_id uuid not null references public.assinaturas(id) on delete restrict,
  competencia date not null,
  valor numeric(12,2) not null check (valor >= 0),
  vencimento date not null,
  status text not null default 'aberta' check (status in ('aberta', 'paga', 'vencida', 'cancelada')),
  pago_em date,
  forma_pagamento text,
  id_externo text,
  created_at timestamptz not null default now(),
  unique (assinatura_id, competencia)
);

create table public.chamadas_aos_sistemas (
  id uuid primary key default gen_random_uuid(),
  sistema_id uuid not null references public.sistemas(id),
  assinatura_id uuid references public.assinaturas(id),
  acao text not null,
  pedido jsonb not null default '{}',
  resposta jsonb,
  ok boolean not null,
  created_at timestamptz not null default now()
);

create index assinaturas_cliente on public.assinaturas (cliente_id);
create index cobrancas_assinatura on public.cobrancas (assinatura_id);
create index chamadas_sistema on public.chamadas_aos_sistemas (sistema_id, created_at desc);
create index chamadas_assinatura on public.chamadas_aos_sistemas (assinatura_id);

alter table public.sistemas enable row level security;
alter table public.clientes_portal enable row level security;
alter table public.assinaturas enable row level security;
alter table public.cobrancas enable row level security;
alter table public.chamadas_aos_sistemas enable row level security;

-- sem política: só a chave de serviço (Edge Functions) lê e grava
revoke all on all tables in schema public from anon, authenticated;

insert into public.sistemas (codigo, nome, url_api, chave_segredo)
values ('transporte', 'Transporte', 'https://tindhrtijvqkxdeiqzil.supabase.co/functions/v1/portal-assinaturas', 'PORTAL_KEY_TRANSPORTE');
