-- Ícone de cada sistema na tela principal, situação do teste/assinatura guardada no portal e documento único por cliente
-- (o mesmo CNPJ/CPF em vários sistemas é o mesmo cliente).

alter table public.sistemas add column icone text not null default 'app';
update public.sistemas set icone = 'caminhao' where codigo = 'transporte';

alter table public.assinaturas
  add column status text,
  add column trial_ate date,
  add column origem text not null default 'manual' check (origem in ('manual', 'cadastro', 'sincronizacao')),
  add column sincronizada_em timestamptz;

create unique index clientes_portal_documento on public.clientes_portal (documento) where documento is not null;
