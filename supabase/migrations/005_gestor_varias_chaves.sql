-- Gestor+: uma empresa pode ter várias chaves (cada uma com os seus computadores e o seu limite), como no cadastro antigo.
-- O limite da chave sobrescreve o da empresa/plano. Funções que falavam "a chave da empresa" passam a receber a chave quando há mais de uma.

drop index gestor.ux_gestor_licencas_empresa;
create index ix_gestor_licencas_empresa on gestor.licencas (empresa_id);
alter table gestor.licencas add column limite_computadores integer check (limite_computadores is null or limite_computadores >= 1);

create function gestor.limite_da_chave(p_chave text) returns integer language sql stable security definer set search_path = '' as $$
  select coalesce(l.limite_computadores, gestor.limite_da_empresa(l.empresa_id)) from gestor.licencas l where l.chave = p_chave
$$;

create or replace function public.gestor_app_ativar(p_chave text, p_maquina text, p_nome text default null, p_versao text default null) returns jsonb language plpgsql security definer set search_path = '' as $$
declare l gestor.licencas%rowtype; v_limite int; v_usados int; v_ja boolean;
begin
  if coalesce(p_chave, '') !~ '^[A-Z0-9-]{12,40}$' then perform gestor.falha('Chave inválida. Confira se digitou exatamente como recebeu.', 400); end if;
  if coalesce(p_maquina, '') !~ '^[A-Za-z0-9_-]{8,64}$' then perform gestor.falha('Computador não identificado.', 400); end if;
  select * into l from gestor.licencas where chave = p_chave for update;
  if not found then perform gestor.falha('Chave não encontrada. Confira se digitou corretamente.', 404); end if;
  if l.status <> 'ativa' then perform gestor.falha('Esta licença está bloqueada. Entre em contato com o fornecedor.', 403); end if;
  v_limite := gestor.limite_da_chave(p_chave);
  select count(*), coalesce(bool_or(maquina = p_maquina), false) into v_usados, v_ja from gestor.maquinas where chave = p_chave;
  if not v_ja and v_limite is not null and v_usados >= v_limite then
    perform gestor.falha('Esta chave já está ativada em ' || v_usados || ' computador(es) (limite: ' || v_limite || '). Peça ao fornecedor para liberar um computador.', 409);
  end if;
  insert into gestor.maquinas (chave, maquina, nome, versao, ultimo_contato) values (p_chave, p_maquina, left(p_nome, 80), left(p_versao, 20), now())
  on conflict (chave, maquina) do update set nome = coalesce(excluded.nome, gestor.maquinas.nome), versao = coalesce(excluded.versao, gestor.maquinas.versao), ultimo_contato = now();
  if not v_ja then perform gestor.evento(l.empresa_id, 'computador_ativado', null, null, jsonb_strip_nulls(jsonb_build_object('nome', left(p_nome, 80))), 'app'); end if;
  return gestor.licenca_json(p_chave, p_maquina);
end $$;

create or replace function public.gestor_portal_listar_empresas(p_busca text default null, p_status text default null, p_limite int default 25, p_deslocamento int default 0)
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
      'chaves', (select count(*) from gestor.licencas l where l.empresa_id = p.id),
      'chave', (select l.chave from gestor.licencas l where l.empresa_id = p.id order by l.created_at, l.chave limit 1)
    ) order by p.created_at desc, p.id), '[]'::jsonb) into v_lista
  from (select * from gestor.empresas e where (p_status is null or e.status = p_status)
          and (v_like is null or e.nome ilike v_like or e.nome_fantasia ilike v_like or (v_dig <> '' and e.documento like '%' || v_dig || '%'))
        order by e.created_at desc, e.id limit v_lim offset v_off) p
  cross join lateral (select gestor.estado(p.id) as st) s;
  return jsonb_build_object('total', v_total, 'empresas', v_lista);
end $$;

drop function public.gestor_portal_licenca(uuid);
create function public.gestor_portal_licenca(p_empresa uuid) returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare e gestor.empresas%rowtype; pl gestor.planos%rowtype;
begin
  select * into e from gestor.empresas where id = p_empresa;
  if not found then perform gestor.falha('Empresa não encontrada.', 404); end if;
  select * into pl from gestor.planos where codigo = e.plano_codigo;
  return jsonb_build_object(
    'empresa', jsonb_build_object('empresa_id', e.id, 'nome', e.nome, 'nome_fantasia', e.nome_fantasia, 'documento', e.documento, 'email', e.email, 'telefone', e.telefone,
                'plano_codigo', e.plano_codigo, 'plano_nome', pl.nome, 'status', e.status, 'trial_ate', e.trial_ate),
    'licencas', coalesce((select jsonb_agg(jsonb_build_object('chave', l.chave, 'status', l.status, 'email_enviado_em', l.email_enviado_em, 'criada_em', l.created_at,
        'limite_computadores', gestor.limite_da_chave(l.chave), 'limite_proprio', l.limite_computadores,
        'maquinas', coalesce((select jsonb_agg(jsonb_build_object('maquina', m.maquina, 'nome', m.nome, 'versao', m.versao, 'ativada_em', m.ativada_em, 'ultimo_contato', m.ultimo_contato) order by m.ativada_em)
                              from gestor.maquinas m where m.chave = l.chave), '[]'::jsonb)) order by l.created_at, l.chave) from gestor.licencas l where l.empresa_id = p_empresa), '[]'::jsonb),
    'limite_computadores', gestor.limite_da_empresa(p_empresa), 'vencimento', e.vencimento, 'situacao', gestor.estado(p_empresa));
end $$;

-- modos: 'se_nao_houver' (padrão: devolve a chave existente), 'adicionar' (mais uma chave) e 'substituir' (troca a chave p_chave: a antiga e os computadores dela deixam de valer)
drop function public.gestor_portal_gerar_chave(uuid, boolean);
create function public.gestor_portal_gerar_chave(p_empresa uuid, p_modo text default 'se_nao_houver', p_chave text default null) returns jsonb language plpgsql security definer set search_path = '' as $$
declare l gestor.licencas%rowtype; v_nova text; v_lim int;
begin
  if coalesce(p_modo, '') not in ('se_nao_houver', 'adicionar', 'substituir') then perform gestor.falha('Modo inválido.', 400); end if;
  if not exists (select 1 from gestor.empresas where id = p_empresa for update) then perform gestor.falha('Empresa não encontrada.', 404); end if;
  if p_modo = 'se_nao_houver' then
    select * into l from gestor.licencas where empresa_id = p_empresa order by created_at, chave limit 1;
    if found then return jsonb_build_object('chave', l.chave, 'nova', false, 'status', l.status); end if;
  elsif p_modo = 'substituir' then
    select * into l from gestor.licencas where empresa_id = p_empresa and chave = p_chave;
    if not found then perform gestor.falha('Chave não encontrada nesta empresa.', 404); end if;
    v_lim := l.limite_computadores;
  end if;
  loop
    v_nova := 'GSTR-' || gestor.gerar_codigo(4, 5);
    exit when not exists (select 1 from gestor.licencas where chave = v_nova);
  end loop;
  if p_modo = 'substituir' then delete from gestor.licencas where chave = p_chave; end if;
  insert into gestor.licencas (chave, empresa_id, limite_computadores) values (v_nova, p_empresa, v_lim);
  perform gestor.evento(p_empresa, case p_modo when 'substituir' then 'chave_substituida' else 'chave_gerada' end, null, null, '{}'::jsonb);
  return jsonb_build_object('chave', v_nova, 'nova', true, 'status', 'ativa');
end $$;

drop function public.gestor_portal_marcar_email(uuid);
create function public.gestor_portal_marcar_email(p_empresa uuid, p_chave text) returns jsonb language sql security definer set search_path = '' as $$
  update gestor.licencas set email_enviado_em = now() where empresa_id = p_empresa and chave = p_chave returning jsonb_build_object('email_enviado_em', email_enviado_em)
$$;

drop function public.gestor_portal_bloquear_chave(uuid, boolean, text);
create function public.gestor_portal_bloquear_chave(p_empresa uuid, p_bloquear boolean, p_motivo text default null, p_chave text default null) returns jsonb language plpgsql security definer set search_path = '' as $$
declare l gestor.licencas%rowtype; v_n int; v_motivo text := nullif(left(btrim(coalesce(p_motivo, '')), 300), '');
begin
  select count(*) into v_n from gestor.licencas where empresa_id = p_empresa;
  if v_n = 0 then perform gestor.falha('Esta empresa ainda não tem chave.', 404); end if;
  if p_chave is null then
    if v_n > 1 then perform gestor.falha('Esta empresa tem mais de uma chave: escolha qual.', 400); end if;
    select * into l from gestor.licencas where empresa_id = p_empresa for update;
  else
    select * into l from gestor.licencas where empresa_id = p_empresa and chave = p_chave for update;
    if not found then perform gestor.falha('Chave não encontrada nesta empresa.', 404); end if;
  end if;
  update gestor.licencas set status = case when p_bloquear then 'bloqueada' else 'ativa' end where chave = l.chave;
  perform gestor.evento(p_empresa, case when p_bloquear then 'chave_bloqueada' else 'chave_desbloqueada' end, jsonb_build_object('status', l.status),
    jsonb_build_object('status', case when p_bloquear then 'bloqueada' else 'ativa' end), jsonb_strip_nulls(jsonb_build_object('motivo', v_motivo, 'chave', '…' || right(l.chave, 5))));
  return jsonb_build_object('status', case when p_bloquear then 'bloqueada' else 'ativa' end);
end $$;

drop function public.gestor_portal_liberar_maquina(uuid, text);
create function public.gestor_portal_liberar_maquina(p_empresa uuid, p_maquina text, p_chave text default null) returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_n int;
begin
  delete from gestor.maquinas m using gestor.licencas l
   where l.chave = m.chave and l.empresa_id = p_empresa and m.maquina = p_maquina and (p_chave is null or m.chave = p_chave);
  get diagnostics v_n = row_count;
  if v_n = 0 then perform gestor.falha('Computador não encontrado nesta licença.', 404); end if;
  perform gestor.evento(p_empresa, 'computador_liberado', null, null, jsonb_build_object('maquina', left(p_maquina, 8) || '…'));
  return jsonb_build_object('liberado', true);
end $$;

-- sem p_chave: limite da empresa (vale para as chaves sem limite próprio); com p_chave: limite só daquela chave
drop function public.gestor_portal_definir_limite(uuid, int);
create function public.gestor_portal_definir_limite(p_empresa uuid, p_limite int, p_chave text default null) returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_antes int;
begin
  if p_limite is not null and (p_limite < 1 or p_limite > 1000) then perform gestor.falha('O limite deve ficar entre 1 e 1000 computadores (ou vazio para seguir o plano).', 400); end if;
  if p_chave is null then
    select limite_computadores into v_antes from gestor.empresas where id = p_empresa for update;
    if not found then perform gestor.falha('Empresa não encontrada.', 404); end if;
    update gestor.empresas set limite_computadores = p_limite where id = p_empresa;
  else
    select limite_computadores into v_antes from gestor.licencas where empresa_id = p_empresa and chave = p_chave for update;
    if not found then perform gestor.falha('Chave não encontrada nesta empresa.', 404); end if;
    update gestor.licencas set limite_computadores = p_limite where chave = p_chave;
  end if;
  perform gestor.evento(p_empresa, 'limite_definido', jsonb_build_object('limite', v_antes), jsonb_build_object('limite', p_limite), jsonb_strip_nulls(jsonb_build_object('chave', case when p_chave is null then null else '…' || right(p_chave, 5) end)));
  return jsonb_build_object('limite_computadores', case when p_chave is null then gestor.limite_da_empresa(p_empresa) else gestor.limite_da_chave(p_chave) end);
end $$;

-- importação: o mesmo CNPJ/CPF reaproveita a empresa e acrescenta a chave; `limite_computadores` é o limite DA CHAVE (a da empresa só vem sem chave)
create or replace function public.gestor_portal_importar(p_dados jsonb) returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_emp jsonb := p_dados->'empresa'; v_chave text := upper(btrim(coalesce(p_dados->>'chave', '')));
  v_doc text; v_nome text; v_plano text := coalesce(nullif(p_dados->>'plano_codigo', ''), 'trial'); v_status text := coalesce(nullif(p_dados->>'status', ''), 'ativa');
  v_trial date; v_venc date; v_lim int; v_id uuid; v_m jsonb; v_n int := 0;
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
            v_plano, v_status, v_trial, v_venc, case when v_chave = '' then v_lim end) returning id into v_id;
    perform gestor.evento(v_id, 'importada', null, jsonb_build_object('status', v_status, 'plano_codigo', v_plano), '{}'::jsonb, 'importacao');
  else
    update gestor.empresas set nome = v_nome, nome_fantasia = nullif(btrim(coalesce(v_emp->>'nome_fantasia', '')), ''), documento = coalesce(v_doc, documento),
      email = coalesce(nullif(btrim(coalesce(v_emp->>'email', '')), ''), email), telefone = coalesce(nullif(btrim(coalesce(v_emp->>'telefone', '')), ''), telefone),
      plano_codigo = v_plano, status = v_status, trial_ate = v_trial, vencimento = v_venc, limite_computadores = case when v_chave = '' then v_lim else limite_computadores end where id = v_id;
  end if;
  if v_chave <> '' then
    insert into gestor.licencas (chave, empresa_id, status, email_enviado_em, limite_computadores) values (v_chave, v_id, coalesce(nullif(p_dados->>'chave_status', ''), 'ativa'), now(), v_lim)
    on conflict (chave) do update set status = excluded.status, limite_computadores = excluded.limite_computadores;
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
