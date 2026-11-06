-- Gestor+ no portal: licenças e assinaturas do aplicativo (esquema próprio `gestor`, isolado; só o service_role acessa).
-- Aplicada no projeto Portal em várias etapas; este arquivo é a versão final consolidada. Funções públicas `gestor_*` são o único caminho
-- (chamadas pelas Edge Functions gestor-assinaturas e gestor-licenca). Erros: `raise exception` com hint = status HTTP.

create schema if not exists gestor;
revoke all on schema gestor from public, anon, authenticated;
grant usage on schema gestor to service_role;

create table gestor.config (chave text primary key, valor text not null, atualizado_em timestamptz not null default now());

create table gestor.planos (
  codigo text primary key check (codigo ~ '^[a-z0-9_]{2,30}$'),
  nome text not null check (length(btrim(nome)) between 1 and 60),
  limite_computadores integer check (limite_computadores is null or limite_computadores >= 1),
  preco_mensal numeric(10,2) not null default 0 check (preco_mensal >= 0),
  ativo boolean not null default true,
  created_at timestamptz not null default now()
);
insert into gestor.planos (codigo, nome, limite_computadores, preco_mensal) values ('trial', 'Teste grátis', 1, 0);

create table gestor.empresas (
  id uuid primary key default gen_random_uuid(),
  nome text not null, nome_fantasia text, documento text, email text, telefone text,
  plano_codigo text not null default 'trial' references gestor.planos (codigo),
  status text not null default 'trial' check (status in ('trial', 'ativa', 'suspensa', 'cancelada')),
  trial_ate date,
  limite_computadores integer check (limite_computadores is null or limite_computadores >= 1),  -- sobrescreve o limite do plano
  vencimento date,                                                                               -- vale enquanto o portal não emitir cobranças da assinatura
  solicitada_por text,                                                                           -- computador que fez o pedido pelo app
  created_at timestamptz not null default now()
);
create unique index ux_gestor_empresas_documento on gestor.empresas (documento) where documento is not null;
create index ix_gestor_empresas_solicitada on gestor.empresas (solicitada_por) where solicitada_por is not null;

create table gestor.licencas (
  chave text primary key,
  empresa_id uuid not null references gestor.empresas (id) on delete cascade,
  status text not null default 'ativa' check (status in ('ativa', 'bloqueada')),
  email_enviado_em timestamptz,
  created_at timestamptz not null default now()
);
create unique index ux_gestor_licencas_empresa on gestor.licencas (empresa_id);

create table gestor.maquinas (
  chave text not null references gestor.licencas (chave) on delete cascade,
  maquina text not null, nome text, versao text,
  ativada_em timestamptz not null default now(), ultimo_contato timestamptz,
  primary key (chave, maquina)
);

create table gestor.eventos (
  id uuid primary key default gen_random_uuid(),
  empresa_id uuid not null references gestor.empresas (id) on delete cascade,
  acao text not null, anterior jsonb, depois jsonb, detalhes jsonb not null default '{}'::jsonb,
  origem text not null default 'portal', created_at timestamptz not null default now()
);
create index ix_gestor_eventos_empresa on gestor.eventos (empresa_id, created_at desc);

create table gestor.recuperacoes (
  codigo text primary key,
  empresa_id uuid not null references gestor.empresas (id) on delete cascade,
  expira_em timestamptz not null, usado_em timestamptz, created_at timestamptz not null default now()
);

create table gestor.atualizacao (id integer primary key default 1 check (id = 1), versao text not null, url text not null, publicada_em timestamptz not null default now());

create table gestor.tentativas (id bigint generated always as identity primary key, ip text not null, tipo text not null, quando timestamptz not null default now());
create index ix_gestor_tentativas on gestor.tentativas (ip, tipo, quando);

insert into gestor.config (chave, valor) values ('carencia_dias', '7'), ('aviso_dias', '7');

alter table gestor.config enable row level security;
alter table gestor.planos enable row level security;
alter table gestor.empresas enable row level security;
alter table gestor.licencas enable row level security;
alter table gestor.maquinas enable row level security;
alter table gestor.eventos enable row level security;
alter table gestor.recuperacoes enable row level security;
alter table gestor.atualizacao enable row level security;
alter table gestor.tentativas enable row level security;
grant select, insert, update, delete on all tables in schema gestor to service_role;
grant usage, select on all sequences in schema gestor to service_role;

-- ---------- regra de assinatura ----------
create function gestor.hoje() returns date language sql stable set search_path = '' as $$ select (now() at time zone 'America/Sao_Paulo')::date $$;

create function gestor.limite_da_empresa(p_empresa uuid) returns integer language sql stable security definer set search_path = '' as $$
  select coalesce(e.limite_computadores, p.limite_computadores) from gestor.empresas e join gestor.planos p on p.codigo = e.plano_codigo where e.id = p_empresa
$$;

-- ok → aviso (vence em até aviso_dias) → carencia (vencida há até carencia_dias) → somente_leitura. aguardando = cadastro novo sem liberação;
-- suspensa/cancelada = somente leitura. Vencimento: fim do teste, ou as cobranças do portal (public.cobrancas) se existirem, ou `vencimento` manual.
create function gestor.estado(p_empresa uuid) returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  e gestor.empresas%rowtype; p gestor.planos%rowtype; v_hoje date := gestor.hoje();
  v_carencia int := coalesce(nullif((select valor from gestor.config where chave = 'carencia_dias'), '')::int, 7);
  v_aviso int := coalesce(nullif((select valor from gestor.config where chave = 'aviso_dias'), '')::int, 7);
  v_venc date; v_cobs int; v_estado text; v_dias int;
begin
  select * into e from gestor.empresas where id = p_empresa;
  if not found then return jsonb_build_object('estado', 'inexistente', 'liberada', false); end if;
  select * into p from gestor.planos where codigo = e.plano_codigo;
  if e.status in ('suspensa', 'cancelada') then v_estado := 'somente_leitura';
  elsif e.status = 'trial' and e.trial_ate is null then v_estado := 'aguardando';
  else
    if e.status = 'trial' then v_venc := e.trial_ate;
    else
      select count(*) filter (where c.status <> 'cancelada'), min(c.vencimento) filter (where c.status in ('aberta', 'vencida')) into v_cobs, v_venc
      from public.cobrancas c join public.assinaturas a on a.id = c.assinatura_id join public.sistemas s on s.id = a.sistema_id
      where s.codigo = 'gestor' and a.empresa_id = e.id;
      if v_cobs = 0 then v_venc := e.vencimento; end if;
    end if;
    if v_venc is null or v_venc - v_hoje > v_aviso then v_estado := 'ok';
    elsif v_venc >= v_hoje then v_estado := 'aviso'; v_dias := v_venc - v_hoje;                    -- dias até vencer (0 = vence hoje)
    elsif v_hoje - v_venc <= v_carencia then v_estado := 'carencia'; v_dias := v_carencia - (v_hoje - v_venc);  -- dias de carência que restam
    else v_estado := 'somente_leitura'; v_dias := v_hoje - v_venc;                                  -- dias de atraso
    end if;
  end if;
  return jsonb_build_object('estado', v_estado, 'status', e.status, 'plano_codigo', e.plano_codigo, 'plano_nome', p.nome, 'vencimento', v_venc, 'dias', v_dias,
    'carencia_dias', v_carencia, 'aviso_dias', v_aviso, 'liberada', v_estado in ('ok', 'aviso', 'carencia'));
end $$;

create function gestor.evento(p_empresa uuid, p_acao text, p_antes jsonb, p_depois jsonb, p_detalhes jsonb, p_origem text default 'portal') returns void
language sql security definer set search_path = '' as $$
  insert into gestor.eventos (empresa_id, acao, anterior, depois, detalhes, origem) values (p_empresa, p_acao, p_antes, p_depois, coalesce(p_detalhes, '{}'::jsonb), p_origem)
$$;

create function gestor.falha(p_msg text, p_http int) returns void language plpgsql set search_path = '' as $$
begin raise exception '%', p_msg using hint = p_http::text; end $$;

create function gestor.espelhar(p_empresa uuid) returns void language sql security definer set search_path = '' as $$
  update public.assinaturas a set status = e.status, plano_codigo = e.plano_codigo, trial_ate = e.trial_ate, sincronizada_em = now()
    from gestor.empresas e, public.sistemas s where e.id = p_empresa and s.codigo = 'gestor' and a.sistema_id = s.id and a.empresa_id = e.id
$$;

create function gestor.assinatura_json(p_empresa uuid) returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('empresa_id', e.id, 'status', e.status, 'plano_codigo', e.plano_codigo, 'trial_ate', e.trial_ate,
    'liberada', (gestor.estado(e.id)->>'liberada')::boolean, 'situacao', gestor.estado(e.id)->>'estado', 'vencimento', e.vencimento)
  from gestor.empresas e where e.id = p_empresa
$$;

-- código legível sem I, O, 0 e 1: 32 símbolos, então "byte & 31" não tem viés
create function gestor.gerar_codigo(p_grupos int, p_tam int default 5) returns text language plpgsql volatile security definer set search_path = '' as $$
declare a constant text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; n int := p_grupos * p_tam; b bytea := extensions.gen_random_bytes(p_grupos * p_tam); r text := ''; i int;
begin
  for i in 0 .. n - 1 loop
    r := r || substr(a, (get_byte(b, i) & 31) + 1, 1);
    if (i + 1) % p_tam = 0 and i + 1 < n then r := r || '-'; end if;
  end loop;
  return r;
end $$;

-- o que o app recebe (a borda assina): situação do plano e datas, para o app decidir também sem internet
create function gestor.licenca_json(p_chave text, p_maquina text) returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('chave', l.chave, 'maquina', p_maquina, 'empresa_id', e.id, 'cliente', coalesce(e.nome_fantasia, e.nome),
    'plano_codigo', e.plano_codigo, 'plano_nome', pl.nome, 'status', e.status,
    'base', case when e.status in ('suspensa', 'cancelada') then 'bloqueio' when e.status = 'trial' and e.trial_ate is null then 'aguardando' else 'normal' end,
    'vencimento', s.st->'vencimento', 'aviso_dias', s.st->'aviso_dias', 'carencia_dias', s.st->'carencia_dias', 'estado', s.st->>'estado', 'dias', s.st->'dias',
    'liberada', (s.st->>'estado') in ('ok', 'aviso', 'carencia'))
  from gestor.licencas l join gestor.empresas e on e.id = l.empresa_id join gestor.planos pl on pl.codigo = e.plano_codigo
  cross join lateral (select gestor.estado(e.id) as st) s where l.chave = p_chave
$$;

create function gestor.conferir_maquina(p_chave text, p_maquina text) returns void language plpgsql stable security definer set search_path = '' as $$
declare l gestor.licencas%rowtype;
begin
  select * into l from gestor.licencas where chave = p_chave;
  if not found then perform gestor.falha('A chave de licença não existe mais.', 404); end if;
  if l.status <> 'ativa' then perform gestor.falha('A licença foi bloqueada. Entre em contato com o fornecedor.', 403); end if;
  if not exists (select 1 from gestor.maquinas where chave = p_chave and maquina = p_maquina) then perform gestor.falha('Este computador foi liberado da licença. Ative novamente com a chave.', 403); end if;
end $$;

-- ---------- contrato do portal ----------
create function public.gestor_portal_listar_empresas(p_busca text default null, p_status text default null, p_limite int default 25, p_deslocamento int default 0)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_busca text := nullif(btrim(coalesce(p_busca, '')), ''); v_dig text := regexp_replace(coalesce(p_busca, ''), '\D', '', 'g');
  v_like text; v_total bigint; v_lista jsonb; v_lim int := least(greatest(coalesce(p_limite, 25), 1), 200); v_off int := greatest(coalesce(p_deslocamento, 0), 0);
begin
  if p_status is not null and p_status not in ('trial', 'ativa', 'suspensa', 'cancelada') then perform gestor.falha('Situação inválida.', 400); end if;
  v_like := case when v_busca is null then null else '%' || replace(replace(replace(v_busca, '\', '\\'), '%', '\%'), '_', '\_') || '%' end;
  select count(*) into v_total from gestor.empresas e where (p_status is null or e.status = p_status)
     and (v_like is null or e.nome ilike v_like or e.nome_fantasia ilike v_like or (v_dig <> '' and e.documento like '%' || v_dig || '%'));
  select coalesce(jsonb_agg(jsonb_build_object(
      'empresa_id', p.id, 'nome', p.nome, 'nome_fantasia', p.nome_fantasia, 'documento', p.documento, 'email', p.email, 'telefone', p.telefone,
      'plano_codigo', p.plano_codigo, 'status', p.status, 'trial_ate', p.trial_ate, 'criada_em', p.created_at,
      'liberada', (s.st->>'estado') in ('ok', 'aviso', 'carencia'), 'situacao', s.st->>'estado', 'vencimento', s.st->'vencimento', 'dias', s.st->'dias',
      'usuarios', 0, 'veiculos', 0,
      'computadores', (select count(*) from gestor.maquinas m join gestor.licencas l on l.chave = m.chave where l.empresa_id = p.id),
      'limite_computadores', gestor.limite_da_empresa(p.id),
      'chave', (select l.chave from gestor.licencas l where l.empresa_id = p.id), 'chave_status', (select l.status from gestor.licencas l where l.empresa_id = p.id)
    ) order by p.created_at desc, p.id), '[]'::jsonb) into v_lista
  from (select * from gestor.empresas e where (p_status is null or e.status = p_status)
          and (v_like is null or e.nome ilike v_like or e.nome_fantasia ilike v_like or (v_dig <> '' and e.documento like '%' || v_dig || '%'))
        order by e.created_at desc, e.id limit v_lim offset v_off) p
  cross join lateral (select gestor.estado(p.id) as st) s;
  return jsonb_build_object('total', v_total, 'empresas', v_lista);
end $$;

create function public.gestor_portal_eventos(p_empresa uuid, p_limite int default 10) returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('eventos', coalesce(jsonb_agg(jsonb_build_object('criado_em', x.created_at, 'acao', x.acao, 'anterior', x.anterior, 'depois', x.depois, 'detalhes', x.detalhes) order by x.created_at desc), '[]'::jsonb))
  from (select * from gestor.eventos where empresa_id = p_empresa order by created_at desc limit least(greatest(coalesce(p_limite, 10), 1), 100)) x
$$;

create function gestor.plano_json(p gestor.planos) returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('codigo', p.codigo, 'nome', p.nome, 'max_veiculos', p.limite_computadores, 'max_usuarios', null, 'limite_computadores', p.limite_computadores,
    'preco_mensal', p.preco_mensal, 'ativo', p.ativo, 'empresas', (select count(*) from gestor.empresas e where e.plano_codigo = p.codigo))
$$;

create function public.gestor_portal_listar_planos() returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('planos', coalesce(jsonb_agg(gestor.plano_json(p) order by p.created_at, p.codigo), '[]'::jsonb)) from gestor.planos p
$$;

create function public.gestor_portal_salvar_plano(p_dados jsonb) returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_cod text := btrim(coalesce(p_dados->>'codigo', '')); v_nome text := btrim(coalesce(p_dados->>'nome', ''));
  v_raw jsonb := coalesce(p_dados->'limite_computadores', p_dados->'max_veiculos');  -- max_veiculos: nome que a tela do portal envia
  v_lim int; v_preco numeric := 0; v_ativo boolean := true; v_p gestor.planos%rowtype; v_uso int;
begin
  if v_cod !~ '^[a-z0-9_]{2,30}$' then perform gestor.falha('Código do plano inválido: use de 2 a 30 letras minúsculas, números ou _.', 400); end if;
  if length(v_nome) < 1 or length(v_nome) > 60 then perform gestor.falha('Informe o nome do plano (até 60 caracteres).', 400); end if;
  if v_raw is not null and jsonb_typeof(v_raw) <> 'null' then
    if jsonb_typeof(v_raw) <> 'number' then perform gestor.falha('O limite de computadores deve ser um número inteiro maior que zero.', 400); end if;
    if v_raw::text !~ '^[0-9]{1,6}$' then perform gestor.falha('O limite de computadores deve ser um número inteiro maior que zero.', 400); end if;
    v_lim := (v_raw::text)::int;
    if v_lim < 1 then perform gestor.falha('O limite de computadores deve ser um número inteiro maior que zero.', 400); end if;
  end if;
  if coalesce(p_dados->>'preco_mensal', '') <> '' then
    if (p_dados->>'preco_mensal') !~ '^[0-9]{1,7}(\.[0-9]{1,2})?$' then perform gestor.falha('Preço mensal inválido.', 400); end if;
    v_preco := (p_dados->>'preco_mensal')::numeric;
  end if;
  if p_dados ? 'ativo' then
    if (p_dados->>'ativo') not in ('true', 'false') then perform gestor.falha('Informe se o plano está ativo.', 400); end if;
    v_ativo := (p_dados->>'ativo')::boolean;
  end if;
  if not v_ativo then
    if v_cod = 'trial' then perform gestor.falha('O plano de teste não pode ser desativado.', 409); end if;
    select count(*) into v_uso from gestor.empresas where plano_codigo = v_cod;
    if v_uso > 0 then perform gestor.falha('Este plano está em uso por ' || v_uso || ' empresa(s): troque o plano delas antes de desativar.', 409); end if;
  end if;
  insert into gestor.planos (codigo, nome, limite_computadores, preco_mensal, ativo) values (v_cod, v_nome, v_lim, v_preco, v_ativo)
  on conflict (codigo) do update set nome = excluded.nome, limite_computadores = excluded.limite_computadores, preco_mensal = excluded.preco_mensal, ativo = excluded.ativo
  returning * into v_p;
  return jsonb_build_object('plano', gestor.plano_json(v_p));
end $$;

create function public.gestor_portal_excluir_plano(p_codigo text) returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_uso int;
begin
  if not exists (select 1 from gestor.planos where codigo = p_codigo) then perform gestor.falha('Plano não encontrado.', 404); end if;
  if p_codigo = 'trial' then perform gestor.falha('O plano de teste não pode ser excluído.', 409); end if;
  select count(*) into v_uso from gestor.empresas where plano_codigo = p_codigo;
  if v_uso > 0 then perform gestor.falha('Este plano está em uso por ' || v_uso || ' empresa(s): troque o plano delas antes de excluir.', 409); end if;
  delete from gestor.planos where codigo = p_codigo;
  return jsonb_build_object('excluido', true);
end $$;

create function public.gestor_portal_alterar_assinatura(p_empresa uuid, p_acao text, p_dados jsonb default '{}'::jsonb) returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  e gestor.empresas%rowtype; v_antes jsonb; v_depois jsonb; v_motivo text := nullif(btrim(coalesce(p_dados->>'motivo', '')), ''); v_dias int; v_plano text;
begin
  if v_motivo is not null and length(v_motivo) > 300 then perform gestor.falha('O motivo pode ter até 300 caracteres.', 400); end if;
  select * into e from gestor.empresas where id = p_empresa for update;
  if not found then perform gestor.falha('Empresa não encontrada.', 404); end if;
  v_antes := jsonb_build_object('status', e.status, 'plano_codigo', e.plano_codigo, 'trial_ate', e.trial_ate);
  if p_acao = 'ativar' then update gestor.empresas set status = 'ativa' where id = e.id;
  elsif p_acao = 'suspender' then update gestor.empresas set status = 'suspensa' where id = e.id;
  elsif p_acao = 'cancelar' then update gestor.empresas set status = 'cancelada' where id = e.id;
  elsif p_acao = 'estender_teste' then
    if e.status <> 'trial' then perform gestor.falha('Só dá para estender o teste de uma assinatura em teste.', 409); end if;
    if coalesce(p_dados->>'dias', '') !~ '^[0-9]{1,3}$' then perform gestor.falha('Informe os dias de teste (de 1 a 365).', 400); end if;
    v_dias := (p_dados->>'dias')::int;
    if v_dias < 1 or v_dias > 365 then perform gestor.falha('Informe os dias de teste (de 1 a 365).', 400); end if;
    update gestor.empresas set trial_ate = greatest(coalesce(e.trial_ate, gestor.hoje()), gestor.hoje()) + v_dias where id = e.id;
  elsif p_acao = 'trocar_plano' then
    v_plano := btrim(coalesce(p_dados->>'plano_codigo', ''));
    if not exists (select 1 from gestor.planos where codigo = v_plano and (ativo or v_plano = e.plano_codigo)) then perform gestor.falha('Plano inexistente ou desativado.', 400); end if;
    update gestor.empresas set plano_codigo = v_plano where id = e.id;
  else perform gestor.falha('Ação inválida.', 400);
  end if;
  select * into e from gestor.empresas where id = p_empresa;
  v_depois := jsonb_build_object('status', e.status, 'plano_codigo', e.plano_codigo, 'trial_ate', e.trial_ate);
  perform gestor.evento(e.id, p_acao, v_antes, v_depois, jsonb_strip_nulls(jsonb_build_object('motivo', v_motivo, 'dias', v_dias, 'plano_codigo', v_plano)));
  perform gestor.espelhar(e.id);
  return gestor.assinatura_json(e.id);
end $$;

-- ---------- app (aplicativo Gestor+) ----------
create function public.gestor_app_limitar(p_ip text, p_tipo text, p_max int, p_minutos int) returns void language plpgsql security definer set search_path = '' as $$
declare n int; v_ip text := left(coalesce(nullif(btrim(p_ip), ''), 'desconhecido'), 80);
begin
  select count(*) into n from gestor.tentativas where ip = v_ip and tipo = p_tipo and quando > now() - make_interval(mins => p_minutos);
  if n >= p_max then perform gestor.falha('Muitas tentativas seguidas. Aguarde alguns minutos e tente de novo.', 429); end if;
  insert into gestor.tentativas (ip, tipo) values (v_ip, p_tipo);
  if random() < 0.02 then delete from gestor.tentativas where quando < now() - interval '1 day'; end if;
end $$;

create function public.gestor_app_ativar(p_chave text, p_maquina text, p_nome text default null, p_versao text default null) returns jsonb language plpgsql security definer set search_path = '' as $$
declare l gestor.licencas%rowtype; v_limite int; v_usados int; v_ja boolean;
begin
  if coalesce(p_chave, '') !~ '^[A-Z0-9-]{12,40}$' then perform gestor.falha('Chave inválida. Confira se digitou exatamente como recebeu.', 400); end if;
  if coalesce(p_maquina, '') !~ '^[A-Za-z0-9_-]{8,64}$' then perform gestor.falha('Computador não identificado.', 400); end if;
  select * into l from gestor.licencas where chave = p_chave for update;
  if not found then perform gestor.falha('Chave não encontrada. Confira se digitou corretamente.', 404); end if;
  if l.status <> 'ativa' then perform gestor.falha('Esta licença está bloqueada. Entre em contato com o fornecedor.', 403); end if;
  v_limite := gestor.limite_da_empresa(l.empresa_id);
  select count(*), coalesce(bool_or(maquina = p_maquina), false) into v_usados, v_ja from gestor.maquinas where chave = p_chave;
  if not v_ja and v_limite is not null and v_usados >= v_limite then
    perform gestor.falha('Esta chave já está ativada em ' || v_usados || ' computador(es) (limite: ' || v_limite || '). Peça ao fornecedor para liberar um computador.', 409);
  end if;
  insert into gestor.maquinas (chave, maquina, nome, versao, ultimo_contato) values (p_chave, p_maquina, left(p_nome, 80), left(p_versao, 20), now())
  on conflict (chave, maquina) do update set nome = coalesce(excluded.nome, gestor.maquinas.nome), versao = coalesce(excluded.versao, gestor.maquinas.versao), ultimo_contato = now();
  if not v_ja then perform gestor.evento(l.empresa_id, 'computador_ativado', null, null, jsonb_strip_nulls(jsonb_build_object('nome', left(p_nome, 80))), 'app'); end if;
  return gestor.licenca_json(p_chave, p_maquina);
end $$;

create function public.gestor_app_validar(p_chave text, p_maquina text, p_versao text default null) returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  if coalesce(p_chave, '') !~ '^[A-Z0-9-]{12,40}$' or coalesce(p_maquina, '') !~ '^[A-Za-z0-9_-]{8,64}$' then perform gestor.falha('Dados inválidos.', 400); end if;
  perform gestor.conferir_maquina(p_chave, p_maquina);
  update gestor.maquinas set ultimo_contato = now(), versao = coalesce(left(p_versao, 20), versao) where chave = p_chave and maquina = p_maquina;
  return gestor.licenca_json(p_chave, p_maquina);
end $$;

create function public.gestor_app_solicitar(p_cliente text, p_documento text, p_email text, p_telefone text, p_maquina text) returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_nome text := btrim(coalesce(p_cliente, '')); v_doc text := regexp_replace(coalesce(p_documento, ''), '\D', '', 'g'); v_email text := btrim(coalesce(p_email, ''));
  v_ex gestor.empresas%rowtype; v_id uuid;
begin
  if length(v_nome) < 2 or length(v_nome) > 200 then perform gestor.falha('Informe o nome ou a razão social.', 400); end if;
  if v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' or length(v_email) > 200 then perform gestor.falha('Informe um e-mail válido: é para lá que a chave será enviada.', 400); end if;
  if length(v_doc) not in (11, 14) then perform gestor.falha('Informe o CPF ou CNPJ completo.', 400); end if;
  if coalesce(p_maquina, '') !~ '^[A-Za-z0-9_-]{8,64}$' then perform gestor.falha('Computador não identificado.', 400); end if;
  select * into v_ex from gestor.empresas where solicitada_por = p_maquina limit 1;
  if found then
    perform gestor.falha('Você já enviou uma solicitação em ' || to_char(v_ex.created_at at time zone 'America/Sao_Paulo', 'DD/MM/YYYY') || ' (e-mail: ' || coalesce(v_ex.email, '—') || '). Aguarde o recebimento da chave no e-mail informado.', 409);
  end if;
  if exists (select 1 from gestor.empresas where documento = v_doc) then
    perform gestor.falha('Já existe um cadastro com este CPF/CNPJ. Se você já recebeu uma chave, use "Tenho uma chave"; senão, fale com o suporte.', 409);
  end if;
  insert into gestor.empresas (nome, documento, email, telefone, plano_codigo, status, trial_ate, solicitada_por)
  values (v_nome, v_doc, v_email, left(nullif(btrim(coalesce(p_telefone, '')), ''), 40), 'trial', 'trial', null, p_maquina) returning id into v_id;
  perform gestor.evento(v_id, 'cadastro', null, jsonb_build_object('status', 'trial', 'plano_codigo', 'trial'), '{}'::jsonb, 'app');
  return (select jsonb_build_object('empresa_id', e.id, 'nome', e.nome, 'nome_fantasia', e.nome_fantasia, 'documento', e.documento, 'email', e.email, 'telefone', e.telefone,
            'plano_codigo', e.plano_codigo, 'status', e.status, 'trial_ate', e.trial_ate) from gestor.empresas e where e.id = v_id);
end $$;

create function public.gestor_app_atualizacao(p_chave text, p_maquina text) returns jsonb language plpgsql security definer set search_path = '' as $$
declare a gestor.atualizacao%rowtype;
begin
  perform gestor.conferir_maquina(p_chave, p_maquina);
  select * into a from gestor.atualizacao where id = 1;
  if not found then return '{}'::jsonb; end if;
  return jsonb_build_object('versao', a.versao, 'url', a.url);
end $$;

create function public.gestor_app_recuperar(p_chave text, p_maquina text, p_codigo text, p_consumir boolean default false) returns jsonb language plpgsql security definer set search_path = '' as $$
declare r gestor.recuperacoes%rowtype; l gestor.licencas%rowtype; v_cod text := upper(regexp_replace(coalesce(p_codigo, ''), '\s', '', 'g'));
begin
  if v_cod !~ '^REC-[A-Z0-9-]{8,30}$' then perform gestor.falha('Código inválido. Digite exatamente como o suporte informou (começa com REC-).', 400); end if;
  perform gestor.conferir_maquina(p_chave, p_maquina);
  select * into l from gestor.licencas where chave = p_chave;
  select * into r from gestor.recuperacoes where codigo = v_cod for update;
  if not found then perform gestor.falha('Código não encontrado. Confira com o suporte.', 404); end if;
  if r.usado_em is not null then perform gestor.falha('Este código já foi utilizado. Peça um novo ao suporte.', 409); end if;
  if r.expira_em <= now() then perform gestor.falha('Este código expirou. Peça um novo ao suporte.', 409); end if;
  if r.empresa_id <> l.empresa_id then perform gestor.falha('Este código foi gerado para outra licença.', 403); end if;
  if p_consumir then
    update gestor.recuperacoes set usado_em = now() where codigo = v_cod;
    perform gestor.evento(l.empresa_id, 'recuperacao_usada', null, null, '{}'::jsonb, 'app');
  end if;
  return jsonb_build_object('codigo', v_cod, 'consumido', coalesce(p_consumir, false));
end $$;

-- ---------- ações extras do portal ----------
create function public.gestor_portal_licenca(p_empresa uuid) returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare l gestor.licencas%rowtype; e gestor.empresas%rowtype; pl gestor.planos%rowtype;
begin
  select * into e from gestor.empresas where id = p_empresa;
  if not found then perform gestor.falha('Empresa não encontrada.', 404); end if;
  select * into pl from gestor.planos where codigo = e.plano_codigo;
  select * into l from gestor.licencas where empresa_id = p_empresa;
  return jsonb_build_object(
    'empresa', jsonb_build_object('empresa_id', e.id, 'nome', e.nome, 'nome_fantasia', e.nome_fantasia, 'documento', e.documento, 'email', e.email, 'telefone', e.telefone,
                'plano_codigo', e.plano_codigo, 'plano_nome', pl.nome, 'status', e.status, 'trial_ate', e.trial_ate),
    'licenca', case when l.chave is null then null else jsonb_build_object('chave', l.chave, 'status', l.status, 'email_enviado_em', l.email_enviado_em, 'criada_em', l.created_at) end,
    'maquinas', coalesce((select jsonb_agg(jsonb_build_object('maquina', m.maquina, 'nome', m.nome, 'versao', m.versao, 'ativada_em', m.ativada_em, 'ultimo_contato', m.ultimo_contato) order by m.ativada_em) from gestor.maquinas m where m.chave = l.chave), '[]'::jsonb),
    'limite_computadores', gestor.limite_da_empresa(p_empresa), 'vencimento', e.vencimento, 'situacao', gestor.estado(p_empresa));
end $$;

create function public.gestor_portal_gerar_chave(p_empresa uuid, p_substituir boolean default false) returns jsonb language plpgsql security definer set search_path = '' as $$
declare l gestor.licencas%rowtype; v_nova text;
begin
  if not exists (select 1 from gestor.empresas where id = p_empresa for update) then perform gestor.falha('Empresa não encontrada.', 404); end if;
  select * into l from gestor.licencas where empresa_id = p_empresa;
  if found and not coalesce(p_substituir, false) then return jsonb_build_object('chave', l.chave, 'nova', false, 'status', l.status); end if;
  loop
    v_nova := 'GSTR-' || gestor.gerar_codigo(4, 5);
    exit when not exists (select 1 from gestor.licencas where chave = v_nova);
  end loop;
  if found then delete from gestor.licencas where empresa_id = p_empresa; end if;  -- a antiga (e os computadores dela) deixa de valer: o cliente ativa de novo com a nova
  insert into gestor.licencas (chave, empresa_id) values (v_nova, p_empresa);
  perform gestor.evento(p_empresa, case when coalesce(p_substituir, false) then 'chave_substituida' else 'chave_gerada' end, null, null, '{}'::jsonb);
  return jsonb_build_object('chave', v_nova, 'nova', true, 'status', 'ativa');
end $$;

create function public.gestor_portal_marcar_email(p_empresa uuid) returns jsonb language sql security definer set search_path = '' as $$
  update gestor.licencas set email_enviado_em = now() where empresa_id = p_empresa returning jsonb_build_object('email_enviado_em', email_enviado_em)
$$;

create function public.gestor_portal_bloquear_chave(p_empresa uuid, p_bloquear boolean, p_motivo text default null) returns jsonb language plpgsql security definer set search_path = '' as $$
declare l gestor.licencas%rowtype; v_motivo text := nullif(left(btrim(coalesce(p_motivo, '')), 300), '');
begin
  select * into l from gestor.licencas where empresa_id = p_empresa for update;
  if not found then perform gestor.falha('Esta empresa ainda não tem chave.', 404); end if;
  update gestor.licencas set status = case when p_bloquear then 'bloqueada' else 'ativa' end where chave = l.chave;
  perform gestor.evento(p_empresa, case when p_bloquear then 'chave_bloqueada' else 'chave_desbloqueada' end, jsonb_build_object('status', l.status),
    jsonb_build_object('status', case when p_bloquear then 'bloqueada' else 'ativa' end), jsonb_strip_nulls(jsonb_build_object('motivo', v_motivo)));
  return jsonb_build_object('status', case when p_bloquear then 'bloqueada' else 'ativa' end);
end $$;

create function public.gestor_portal_liberar_maquina(p_empresa uuid, p_maquina text) returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_chave text; v_n int;
begin
  select chave into v_chave from gestor.licencas where empresa_id = p_empresa;
  if v_chave is null then perform gestor.falha('Esta empresa ainda não tem chave.', 404); end if;
  delete from gestor.maquinas where chave = v_chave and maquina = p_maquina;
  get diagnostics v_n = row_count;
  if v_n = 0 then perform gestor.falha('Computador não encontrado nesta licença.', 404); end if;
  perform gestor.evento(p_empresa, 'computador_liberado', null, null, jsonb_build_object('maquina', left(p_maquina, 8) || '…'));
  return jsonb_build_object('liberado', true);
end $$;

create function public.gestor_portal_definir_limite(p_empresa uuid, p_limite int) returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_antes int;
begin
  if p_limite is not null and (p_limite < 1 or p_limite > 1000) then perform gestor.falha('O limite deve ficar entre 1 e 1000 computadores (ou vazio para seguir o plano).', 400); end if;
  select limite_computadores into v_antes from gestor.empresas where id = p_empresa for update;
  if not found then perform gestor.falha('Empresa não encontrada.', 404); end if;
  update gestor.empresas set limite_computadores = p_limite where id = p_empresa;
  perform gestor.evento(p_empresa, 'limite_definido', jsonb_build_object('limite', v_antes), jsonb_build_object('limite', p_limite), '{}'::jsonb);
  return jsonb_build_object('limite_computadores', gestor.limite_da_empresa(p_empresa));
end $$;

-- vencimento manual: { data: 'AAAA-MM-DD' | null } ou { meses: N } (soma a partir do vencimento atual ou de hoje)
create function public.gestor_portal_definir_vencimento(p_empresa uuid, p_dados jsonb) returns jsonb language plpgsql security definer set search_path = '' as $$
declare e gestor.empresas%rowtype; v_novo date; v_meses int; v_motivo text := nullif(left(btrim(coalesce(p_dados->>'motivo', '')), 300), '');
begin
  select * into e from gestor.empresas where id = p_empresa for update;
  if not found then perform gestor.falha('Empresa não encontrada.', 404); end if;
  if e.status <> 'ativa' then perform gestor.falha('O vencimento vale para assinaturas ativas. No teste, use "Estender teste".', 409); end if;
  if coalesce(p_dados->>'meses', '') <> '' then
    if (p_dados->>'meses') !~ '^[0-9]{1,2}$' then perform gestor.falha('Informe os meses (de 1 a 60).', 400); end if;
    v_meses := (p_dados->>'meses')::int;
    if v_meses < 1 or v_meses > 60 then perform gestor.falha('Informe os meses (de 1 a 60).', 400); end if;
    v_novo := (greatest(coalesce(e.vencimento, gestor.hoje()), gestor.hoje()) + make_interval(months => v_meses))::date;
  elsif p_dados ? 'data' then
    if jsonb_typeof(p_dados->'data') = 'null' then v_novo := null;
    else
      if (p_dados->>'data') !~ '^\d{4}-\d{2}-\d{2}$' then perform gestor.falha('Data inválida.', 400); end if;
      v_novo := (p_dados->>'data')::date;
    end if;
  else perform gestor.falha('Informe a data ou os meses.', 400);
  end if;
  update gestor.empresas set vencimento = v_novo where id = p_empresa;
  perform gestor.evento(p_empresa, 'vencimento_definido', jsonb_build_object('vencimento', e.vencimento), jsonb_build_object('vencimento', v_novo), jsonb_strip_nulls(jsonb_build_object('motivo', v_motivo)));
  return gestor.assinatura_json(p_empresa);
end $$;

create function public.gestor_portal_gerar_recuperacao(p_empresa uuid) returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_cod text; v_exp timestamptz := now() + interval '24 hours';
begin
  if not exists (select 1 from gestor.licencas where empresa_id = p_empresa) then perform gestor.falha('Esta empresa ainda não tem chave: não há o que recuperar.', 404); end if;
  loop
    v_cod := 'REC-' || gestor.gerar_codigo(2, 5);
    exit when not exists (select 1 from gestor.recuperacoes where codigo = v_cod);
  end loop;
  insert into gestor.recuperacoes (codigo, empresa_id, expira_em) values (v_cod, p_empresa, v_exp);
  perform gestor.evento(p_empresa, 'recuperacao_gerada', null, null, '{}'::jsonb);
  return jsonb_build_object('codigo', v_cod, 'expira_em', v_exp);
end $$;

create function public.gestor_portal_publicar_atualizacao(p_versao text, p_url text) returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  if coalesce(p_versao, '') !~ '^\d{1,3}\.\d{1,3}\.\d{1,3}$' then perform gestor.falha('Versão inválida (use 1.2.3).', 400); end if;
  if coalesce(p_url, '') !~ '^https://[^\s]+$' or length(p_url) > 500 then perform gestor.falha('Endereço do instalador inválido (use https://…).', 400); end if;
  insert into gestor.atualizacao (id, versao, url, publicada_em) values (1, p_versao, p_url, now())
  on conflict (id) do update set versao = excluded.versao, url = excluded.url, publicada_em = now();
  return jsonb_build_object('versao', p_versao, 'url', p_url);
end $$;

-- cadastro direto pelo portal / importação de cliente que já existia (mantém a mesma chave e os computadores já ativados)
create function public.gestor_portal_importar(p_dados jsonb) returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_emp jsonb := p_dados->'empresa'; v_chave text := upper(btrim(coalesce(p_dados->>'chave', '')));
  v_doc text; v_nome text; v_plano text := coalesce(nullif(p_dados->>'plano_codigo', ''), 'trial'); v_status text := coalesce(nullif(p_dados->>'status', ''), 'ativa');
  v_trial date; v_venc date; v_lim int; v_id uuid; v_outra text; v_m jsonb; v_n int := 0;
begin
  if v_chave <> '' and v_chave !~ '^[A-Z0-9-]{12,40}$' then perform gestor.falha('Chave inválida.', 400); end if;
  if v_emp is null or jsonb_typeof(v_emp) <> 'object' then perform gestor.falha('Informe os dados da empresa.', 400); end if;
  v_nome := btrim(coalesce(v_emp->>'nome', ''));
  if length(v_nome) < 2 or length(v_nome) > 200 then perform gestor.falha('Informe o nome da empresa.', 400); end if;
  v_doc := nullif(regexp_replace(coalesce(v_emp->>'documento', ''), '\D', '', 'g'), '');
  if v_status not in ('trial', 'ativa', 'suspensa', 'cancelada') then perform gestor.falha('Situação inválida.', 400); end if;
  if not exists (select 1 from gestor.planos where codigo = v_plano) then perform gestor.falha('Plano inexistente: crie o plano antes.', 400); end if;
  if coalesce(p_dados->>'trial_ate', '') ~ '^\d{4}-\d{2}-\d{2}$' then v_trial := (p_dados->>'trial_ate')::date; end if;
  if coalesce(p_dados->>'vencimento', '') ~ '^\d{4}-\d{2}-\d{2}$' then v_venc := (p_dados->>'vencimento')::date; end if;
  if coalesce(p_dados->>'limite_computadores', '') ~ '^[0-9]{1,4}$' then v_lim := (p_dados->>'limite_computadores')::int; end if;
  if v_chave <> '' then select empresa_id into v_id from gestor.licencas where chave = v_chave; end if;
  if v_id is null and v_doc is not null then select id into v_id from gestor.empresas where documento = v_doc; end if;
  if v_id is null then
    insert into gestor.empresas (nome, nome_fantasia, documento, email, telefone, plano_codigo, status, trial_ate, vencimento, limite_computadores)
    values (v_nome, nullif(btrim(coalesce(v_emp->>'nome_fantasia', '')), ''), v_doc, nullif(btrim(coalesce(v_emp->>'email', '')), ''), nullif(btrim(coalesce(v_emp->>'telefone', '')), ''),
            v_plano, v_status, v_trial, v_venc, v_lim) returning id into v_id;
    perform gestor.evento(v_id, 'importada', null, jsonb_build_object('status', v_status, 'plano_codigo', v_plano), '{}'::jsonb, 'importacao');
  else
    update gestor.empresas set nome = v_nome, nome_fantasia = nullif(btrim(coalesce(v_emp->>'nome_fantasia', '')), ''), documento = coalesce(v_doc, documento),
      email = coalesce(nullif(btrim(coalesce(v_emp->>'email', '')), ''), email), telefone = coalesce(nullif(btrim(coalesce(v_emp->>'telefone', '')), ''), telefone),
      plano_codigo = v_plano, status = v_status, trial_ate = v_trial, vencimento = v_venc, limite_computadores = v_lim where id = v_id;
  end if;
  if v_chave <> '' then
    select chave into v_outra from gestor.licencas where empresa_id = v_id;
    if v_outra is not null and v_outra <> v_chave then perform gestor.falha('Esta empresa já tem outra chave (' || v_outra || ').', 409); end if;
    insert into gestor.licencas (chave, empresa_id, status, email_enviado_em) values (v_chave, v_id, coalesce(nullif(p_dados->>'chave_status', ''), 'ativa'), now())
    on conflict (chave) do update set status = excluded.status;
    for v_m in select * from jsonb_array_elements(coalesce(p_dados->'maquinas', '[]'::jsonb)) loop
      if coalesce(v_m->>'maquina', '') ~ '^[A-Za-z0-9_-]{8,64}$' then
        insert into gestor.maquinas (chave, maquina, nome, ativada_em) values (v_chave, v_m->>'maquina', left(v_m->>'nome', 80), coalesce(nullif(v_m->>'ativada_em', '')::timestamptz, now()))
        on conflict (chave, maquina) do nothing;
        v_n := v_n + 1;
      end if;
    end loop;
  end if;
  perform gestor.espelhar(v_id);
  return jsonb_build_object('empresa_id', v_id, 'chave', nullif(v_chave, ''), 'maquinas', v_n);
end $$;

-- par de chaves que assina as licenças (gerado na primeira chamada de gestor-licenca): só a borda lê e grava
create function public.gestor_config_obter(p_chave text) returns text language sql stable security definer set search_path = '' as $$ select valor from gestor.config where chave = p_chave $$;
create function public.gestor_config_criar(p_chave text, p_valor text) returns text language plpgsql security definer set search_path = '' as $$
begin
  insert into gestor.config (chave, valor) values (p_chave, p_valor) on conflict (chave) do nothing;
  return (select valor from gestor.config where chave = p_chave);
end $$;

-- só o service_role (as Edge Functions) executa
do $$
declare f record;
begin
  for f in select p.oid::regprocedure as assinatura from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proname like 'gestor\_%' loop
    execute format('revoke all on function %s from public, anon, authenticated', f.assinatura);
    execute format('grant execute on function %s to service_role', f.assinatura);
  end loop;
end $$;
revoke all on all functions in schema gestor from public, anon, authenticated;
grant execute on all functions in schema gestor to service_role;

-- cadastro do sistema no portal (o segredo PORTAL_KEY_GESTOR é criado em Edge Functions → Secrets)
insert into public.sistemas (codigo, nome, url_api, chave_segredo, ativo, icone)
values ('gestor', 'Gestor+', 'https://vzoyugnoywtgnvabatrw.supabase.co/functions/v1/gestor-assinaturas', 'PORTAL_KEY_GESTOR', true, 'loja')
on conflict (codigo) do nothing;
