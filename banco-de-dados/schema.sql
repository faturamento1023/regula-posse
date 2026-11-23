-- =====================================================================
--  REGULA POSSE — Sistema de Regulação Municipal  (versão 4)
--  Banco de dados: Supabase (PostgreSQL)
--
--  Como usar: Supabase > SQL Editor > New query > cole este arquivo > Run
--  Pode ser executado mais de uma vez; também atualiza bancos das versões 1 e 2.
--  Versão 4: procedimentos.exige_regulacao, consultar_guia(), agendar() respeita a regulação.
--  Versão 5: validação de CPF e CNS no banco, tabela de log de erro.
--  Versão 6: auditoria da reclassificação de risco, reagendamento após falta,
--             vulnerabilidade, acompanhamento pelo paciente.
--  Versão 7: auditoria do cadastro de paciente, log de acesso, exportação
--             MIRA e política de retenção.
--  Versão 8: cadastro de profissionais executantes.
--  Versão 9: catálogo CID-10 com busca por código ou descrição.
--  Versão 10: anexos da solicitação, em bucket privado do Storage.
--
--  Perfis de acesso:
--    admin       -> tudo
--    solicitante -> atendente: cadastra pacientes, registra e agenda solicitações
--    agendador   -> agenda, cadastra locais / procedimentos / agendas
--    executante  -> local de atendimento: confirma execução ou falta pela guia
--    regulador   -> opera a central e decide os pedidos regulados
--
--  Contas novas aguardam liberação.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. TIPOS
-- ---------------------------------------------------------------------
do $$ begin
  create type papel_usuario as enum ('admin','regulador','solicitante','agendador','executante');
exception when duplicate_object then null; end $$;
alter type papel_usuario add value if not exists 'executante';

do $$ begin
  create type prioridade_risco as enum ('vermelho','amarelo','verde','azul');
exception when duplicate_object then null; end $$;

do $$ begin
  create type status_solicitacao as enum
    ('pendente','devolvida','autorizada','negada','agendada','realizada','faltou','cancelada');
exception when duplicate_object then null; end $$;

-- ---------------------------------------------------------------------
-- 2. TABELAS
-- ---------------------------------------------------------------------
create table if not exists unidades (
  id          bigint generated always as identity primary key,
  nome        text not null,
  cnes        text unique,
  tipo        text not null default 'solicitante'
              check (tipo in ('solicitante','executante','ambos')),
  telefone    text,
  endereco    text,
  ativo       boolean not null default true,
  created_at  timestamptz not null default now()
);

create table if not exists perfis (
  id          uuid primary key references auth.users(id) on delete cascade,
  nome        text,
  email       text,
  papel       papel_usuario not null default 'solicitante',
  unidade_id  bigint references unidades(id),
  ativo       boolean not null default true,
  created_at  timestamptz not null default now()
);

create table if not exists procedimentos (
  id             bigint generated always as identity primary key,
  codigo_sigtap  text,
  competencia_sigtap text,
  nome           text not null,
  tipo           text not null default 'consulta'
                 check (tipo in ('consulta','exame','cirurgia','terapia','outro')),
  especialidade  text,
  ativo          boolean not null default true,
  created_at     timestamptz not null default now()
);
-- v4: quando true, a solicitação precisa ser AUTORIZADA pelo regulador antes do agendamento.
-- Padrão false = mesmo comportamento das versões anteriores (vai direto para o agendamento).
alter table procedimentos add column if not exists exige_regulacao boolean not null default false;
alter table procedimentos add column if not exists competencia_sigtap text;
create unique index if not exists procedimentos_codigo_sigtap_uniq on procedimentos (codigo_sigtap);

-- Quais procedimentos cada local de atendimento realiza
create table if not exists unidade_procedimentos (
  unidade_id       bigint not null references unidades(id) on delete cascade,
  procedimento_id  bigint not null references procedimentos(id) on delete cascade,
  primary key (unidade_id, procedimento_id)
);

create table if not exists pacientes (
  id                     bigint generated always as identity primary key,
  nome                   text not null,
  cns                    text unique,
  cpf                    text unique,
  data_nascimento        date not null,
  sexo                   char(1) not null check (sexo in ('M','F','I')),
  nome_mae               text,
  telefone               text,
  bairro                 text,
  endereco               text,
  unidade_referencia_id  bigint references unidades(id),
  created_by             uuid default auth.uid(),
  created_at             timestamptz not null default now()
);
-- campos adicionados na versão 2 (dados pessoais, contatos e endereço)
alter table pacientes
  add column if not exists nome_social  text,
  add column if not exists nome_pai     text,
  add column if not exists telefone2    text,
  add column if not exists email        text,
  add column if not exists contato_nome text,
  add column if not exists cep          text,
  add column if not exists logradouro   text,
  add column if not exists numero       text,
  add column if not exists complemento  text,
  add column if not exists cidade       text,
  add column if not exists uf           char(2);

create table if not exists vagas (
  id                     bigint generated always as identity primary key,
  unidade_executante_id  bigint not null references unidades(id),
  procedimento_id        bigint not null references procedimentos(id),
  profissional           text,
  data                   date not null,
  hora                   time not null,
  status                 text not null default 'livre'
                         check (status in ('livre','ocupada','bloqueada')),
  created_at             timestamptz not null default now()
);

create sequence if not exists protocolo_seq;
create sequence if not exists guia_seq;

create or replace function gerar_protocolo() returns text
language sql volatile as $$
  select to_char(now(), 'YYYY') || lpad(nextval('protocolo_seq')::text, 6, '0');
$$;

create or replace function gerar_guia() returns text
language sql volatile security definer set search_path = public as $$
  select to_char(now(), 'YY') || lpad(nextval('guia_seq')::text, 6, '0');
$$;

create table if not exists solicitacoes (
  id                        bigint generated always as identity primary key,
  protocolo                 text not null unique default gerar_protocolo(),
  paciente_id               bigint not null references pacientes(id),
  procedimento_id           bigint not null references procedimentos(id),
  unidade_solicitante_id    bigint not null references unidades(id),
  profissional_solicitante  text,
  cid10                     text,
  justificativa             text,
  prioridade                prioridade_risco not null default 'verde',
  status                    status_solicitacao not null default 'pendente',
  parecer                   text,
  regulador_id              uuid references perfis(id),
  data_regulacao            timestamptz,
  vaga_id                   bigint references vagas(id),
  created_by                uuid default auth.uid() references perfis(id),
  created_at                timestamptz not null default now(),
  updated_at                timestamptz not null default now()
);
alter table solicitacoes alter column justificativa drop not null;
alter table solicitacoes
  add column if not exists unidade_origem_id  bigint references unidades(id),  -- onde o pedido médico foi emitido
  add column if not exists crm_solicitante    text,
  add column if not exists data_pedido        date,
  add column if not exists numero_guia        text unique,
  add column if not exists data_agendamento   timestamptz,
  add column if not exists data_execucao      timestamptz,
  add column if not exists confirmado_por     uuid references perfis(id),
  add column if not exists obs_execucao       text;

create table if not exists historico (
  id               bigint generated always as identity primary key,
  solicitacao_id   bigint not null references solicitacoes(id) on delete cascade,
  status_anterior  status_solicitacao,
  status_novo      status_solicitacao not null,
  observacao       text,
  usuario_id       uuid references perfis(id) on delete set null,
  created_at       timestamptz not null default now()
);

-- Índices
create index if not exists idx_sol_fila    on solicitacoes (status, prioridade, created_at);
create index if not exists idx_sol_unidade on solicitacoes (unidade_solicitante_id);
create index if not exists idx_sol_pac     on solicitacoes (paciente_id);
create index if not exists idx_sol_vaga    on solicitacoes (vaga_id);
create index if not exists idx_vagas_busca on vagas (procedimento_id, data, status);
create index if not exists idx_vagas_uni   on vagas (unidade_executante_id, data);
create index if not exists idx_pac_nome    on pacientes (lower(nome));
create index if not exists idx_hist_sol    on historico (solicitacao_id);

-- ---------------------------------------------------------------------
-- 3. FUNÇÕES AUXILIARES DE PERMISSÃO
-- ---------------------------------------------------------------------
create or replace function tem_papel(variadic papeis text[]) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from perfis
     where id = auth.uid() and ativo and papel::text = any(papeis)
  );
$$;

create or replace function minha_unidade() returns bigint
language sql stable security definer set search_path = public as $$
  select unidade_id from perfis where id = auth.uid() and ativo;
$$;

-- ---------------------------------------------------------------------
-- 4. TRIGGERS
-- ---------------------------------------------------------------------
create or replace function handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into perfis (id, nome, email, papel, ativo)
  values (
    new.id,
    coalesce(new.raw_user_meta_data->>'nome', split_part(new.email, '@', 1)),
    new.email,
    'solicitante', false
  )
  on conflict (id) do nothing;
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function handle_new_user();

create or replace function touch_updated_at() returns trigger
language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end $$;

drop trigger if exists trg_sol_touch on solicitacoes;
create trigger trg_sol_touch
  before update on solicitacoes
  for each row execute function touch_updated_at();

create or replace function log_solicitacao() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_obs text := nullif(current_setting('regula.obs', true), '');
begin
  if tg_op = 'INSERT' then
    insert into historico (solicitacao_id, status_novo, observacao, usuario_id)
    values (new.id, new.status, 'Solicitação registrada', auth.uid());
  elsif new.status is distinct from old.status or new.vaga_id is distinct from old.vaga_id then
    insert into historico (solicitacao_id, status_anterior, status_novo, observacao, usuario_id)
    values (new.id, old.status, new.status, coalesce(v_obs, new.parecer), auth.uid());
  end if;
  return new;
end $$;

drop trigger if exists trg_sol_log on solicitacoes;
create trigger trg_sol_log
  after insert or update on solicitacoes
  for each row execute function log_solicitacao();

-- ---------------------------------------------------------------------
-- 5. REGRAS DE NEGÓCIO (RPC)
-- ---------------------------------------------------------------------

-- (opcional) Regulação: autorizar / devolver / negar
create or replace function regular_solicitacao(
  p_id bigint, p_acao text, p_prioridade prioridade_risco default null, p_parecer text default null
) returns void
language plpgsql security definer set search_path = public as $$
declare s solicitacoes;
begin
  if not tem_papel('admin','regulador') then
    raise exception 'Apenas reguladores podem regular solicitações';
  end if;
  if p_acao not in ('autorizar','devolver','negar') then
    raise exception 'Ação inválida: %', p_acao;
  end if;
  select * into s from solicitacoes where id = p_id for update;
  if not found then raise exception 'Solicitação não encontrada'; end if;
  if s.status <> 'pendente' then
    raise exception 'A solicitação não está pendente (status atual: %)', s.status;
  end if;
  if p_acao in ('devolver','negar') and coalesce(trim(p_parecer), '') = '' then
    raise exception 'Informe o motivo no parecer';
  end if;
  update solicitacoes set
    status         = case p_acao when 'autorizar' then 'autorizada'
                                 when 'devolver'  then 'devolvida'
                                 else 'negada' end::status_solicitacao,
    prioridade     = coalesce(p_prioridade, prioridade),
    parecer        = nullif(trim(p_parecer), ''),
    regulador_id   = auth.uid(),
    data_regulacao = now()
  where id = p_id;
end $$;

create or replace function reenviar_solicitacao(p_id bigint, p_justificativa text)
returns void
language plpgsql security definer set search_path = public as $$
declare s solicitacoes;
begin
  select * into s from solicitacoes where id = p_id for update;
  if not found then raise exception 'Solicitação não encontrada'; end if;
  if not (tem_papel('admin','regulador') or (tem_papel('solicitante') and coalesce(s.unidade_solicitante_id = minha_unidade(),false))) then
    raise exception 'Sem permissão para reenviar esta solicitação';
  end if;
  if s.status <> 'devolvida' then raise exception 'Somente solicitações devolvidas podem ser reenviadas'; end if;
  perform set_config('regula.obs', 'Reenviada pela unidade após correção', true);
  update solicitacoes set status = 'pendente', justificativa = trim(p_justificativa) where id = p_id;
end $$;

-- remove assinaturas da versão 1 (mudaram)
drop function if exists agendar(bigint, bigint);
drop function if exists gerar_vagas(bigint, bigint, text, date, date, int[], time, time, int);

-- Agendar (ou remarcar) uma solicitação em uma vaga livre. Gera o número da guia.
create or replace function agendar(p_solicitacao bigint, p_vaga bigint)
returns text
language plpgsql security definer set search_path = public as $$
declare s solicitacoes; v vagas; v_guia text; remarcar boolean;
begin
  select * into s from solicitacoes where id = p_solicitacao for update;
  if not found then raise exception 'Solicitação não encontrada'; end if;
  if not (tem_papel('admin','regulador','agendador')
          or (tem_papel('solicitante') and coalesce(s.unidade_solicitante_id = minha_unidade(),false))) then
    raise exception 'Sem permissão para agendar';
  end if;
  if s.status not in ('pendente','autorizada','agendada') then
    raise exception 'Esta solicitação não pode ser agendada (status: %)', s.status;
  end if;
  if s.status = 'pendente' and exists (select 1 from procedimentos where id = s.procedimento_id and exige_regulacao) then
    raise exception 'Este procedimento exige regulação: a solicitação precisa ser autorizada pelo regulador antes do agendamento';
  end if;
  remarcar := s.status = 'agendada';

  select * into v from vagas where id = p_vaga for update;
  if not found or v.status <> 'livre' then raise exception 'Vaga indisponível — escolha outro horário'; end if;
  if v.procedimento_id <> s.procedimento_id then raise exception 'A vaga é de outro procedimento'; end if;
  if v.data < current_date - 1 then raise exception 'A vaga está em data passada'; end if;

  if remarcar and s.vaga_id is not null then
    update vagas set status = 'livre' where id = s.vaga_id;
  end if;
  update vagas set status = 'ocupada' where id = p_vaga;

  v_guia := coalesce(s.numero_guia, gerar_guia());
  perform set_config('regula.obs',
    case when remarcar then 'Remarcado' else 'Agendado' end || ' para ' ||
    to_char(v.data, 'DD/MM/YYYY') || ' às ' || to_char(v.hora, 'HH24:MI') ||
    ' — ' || (select nome from unidades where id = v.unidade_executante_id) || ' — Guia ' || v_guia, true);

  update solicitacoes set
    status = 'agendada', vaga_id = p_vaga, numero_guia = v_guia, data_agendamento = now()
  where id = p_solicitacao;
  return v_guia;
end $$;

-- Situação de uma guia, sem expor dados do paciente (usada pela tela de Confirmação
-- para diferenciar: inexistente / de outro local / encontrada)
create or replace function consultar_guia(p_guia text)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare s solicitacoes; v vagas;
begin
  if auth.uid() is null or not tem_papel('admin','regulador','agendador','executante','solicitante') then
    raise exception 'Sem permissão';
  end if;
  select * into s from solicitacoes where numero_guia = trim(p_guia);
  if not found then return jsonb_build_object('encontrada', false); end if;
  select * into v from vagas where id = s.vaga_id;
  if tem_papel('executante') and v.unidade_executante_id is distinct from minha_unidade() then return jsonb_build_object('encontrada',false); end if;
  if tem_papel('solicitante') and s.unidade_solicitante_id is distinct from minha_unidade() then return jsonb_build_object('encontrada',false); end if;
  return jsonb_build_object(
    'encontrada', true, 'status', s.status, 'data', v.data, 'local_id', v.unidade_executante_id,
    'local_nome', (select nome from unidades where id = v.unidade_executante_id),
    'outro_local', tem_papel('executante') and v.unidade_executante_id is distinct from minha_unidade());
end $$;

-- Local de atendimento confirma execução ou falta pelo número da guia
create or replace function confirmar_atendimento(p_guia text, p_status text, p_obs text default null)
returns void
language plpgsql security definer set search_path = public as $$
declare s solicitacoes; v vagas;
begin
  if p_status not in ('realizada','faltou') then raise exception 'Status inválido'; end if;
  select * into s from solicitacoes where numero_guia = trim(p_guia) for update;
  if not found then raise exception 'Guia % não encontrada', p_guia; end if;
  if s.status <> 'agendada' then
    raise exception 'Esta guia já foi finalizada (status: %)', s.status;
  end if;
  select * into v from vagas where id = s.vaga_id;
  if not (tem_papel('admin','regulador','agendador')
          or (tem_papel('executante') and coalesce(v.unidade_executante_id = minha_unidade(),false))) then
    raise exception 'Esta guia pertence a outro local de atendimento';
  end if;
  if p_status = 'realizada' and v.data > current_date + 1 then
    raise exception 'Não é possível confirmar a execução antes da data agendada (%)', to_char(v.data, 'DD/MM/YYYY');
  end if;

  perform set_config('regula.obs',
    case p_status when 'realizada' then 'Execução confirmada' else 'Falta registrada' end
    || coalesce(' — ' || nullif(trim(p_obs), ''), ''), true);
  update solicitacoes set
    status = p_status::status_solicitacao, data_execucao = now(),
    confirmado_por = auth.uid(), obs_execucao = nullif(trim(p_obs), '')
  where id = s.id;
end $$;

-- Cancelar (ou desfecho manual)
create or replace function registrar_desfecho(p_id bigint, p_status text, p_obs text default null)
returns void
language plpgsql security definer set search_path = public as $$
declare s solicitacoes;
begin
  select * into s from solicitacoes where id = p_id for update;
  if not found then raise exception 'Solicitação não encontrada'; end if;

  if p_status in ('realizada','faltou') then
    if s.numero_guia is null then raise exception 'Solicitação sem guia'; end if;
    perform confirmar_atendimento(s.numero_guia, p_status, p_obs);
    return;
  elsif p_status = 'cancelada' then
    if coalesce(trim(p_obs), '') = '' then raise exception 'Informe o motivo do cancelamento'; end if;
    if not (tem_papel('admin','regulador','agendador') or (tem_papel('solicitante') and coalesce(s.unidade_solicitante_id = minha_unidade(),false))) then
      raise exception 'Sem permissão';
    end if;
    if s.status not in ('pendente','devolvida','autorizada','agendada') then
      raise exception 'Esta solicitação não pode mais ser cancelada';
    end if;
    if s.vaga_id is not null then
      update vagas set status = 'livre' where id = s.vaga_id;
    end if;
  else
    raise exception 'Status inválido: %', p_status;
  end if;

  perform set_config('regula.obs', 'Cancelada — ' || trim(p_obs), true);
  update solicitacoes set status = 'cancelada', vaga_id = null where id = p_id;
end $$;

-- Gerar agenda de vagas: recebe a lista de DATAS (calculada na tela: dias específicos,
-- semanal/quinzenal ou mensal) e os TURNOS do dia em JSON:
--   [{"hora_ini":"07:00","hora_fim":"11:00","intervalo":20,"qtd":1},   -- horário marcado
--    {"hora_ini":"13:00","hora_fim":"13:00","intervalo":0,"qtd":15}]   -- ordem de chegada
-- Datas que já têm agenda do mesmo profissional/local/procedimento são ignoradas.
drop function if exists gerar_vagas(bigint, bigint, text, date, date, int[], time, time, int, int);
create or replace function gerar_vagas(
  p_unidade bigint, p_procedimento bigint, p_profissional text, p_datas date[], p_turnos jsonb
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  d date; t jsonb; m int; k int; n int := 0; ndias int := 0; ignoradas date[] := '{}';
  v_prof text := nullif(trim(p_profissional), ''); hi time; hf time; itv int; qtd int;
begin
  if not tem_papel('admin','agendador','regulador') then raise exception 'Sem permissão para gerar vagas'; end if;
  if p_datas is null or cardinality(p_datas) = 0 then raise exception 'Nenhuma data informada'; end if;
  if cardinality(p_datas) > 400 then raise exception 'Máximo de 400 datas por vez'; end if;
  if p_turnos is null or jsonb_array_length(p_turnos) = 0 then raise exception 'Informe pelo menos um turno'; end if;

  for t in select * from jsonb_array_elements(p_turnos) loop
    hi := (t->>'hora_ini')::time; hf := (t->>'hora_fim')::time;
    itv := coalesce((t->>'intervalo')::int, 0); qtd := coalesce((t->>'qtd')::int, 1);
    if qtd < 1 or qtd > 200 then raise exception 'Quantidade de vagas inválida (1 a 200)'; end if;
    if itv <> 0 and (itv < 5 or hf <= hi) then raise exception 'Turno inválido: confira início, fim e intervalo'; end if;
  end loop;

  insert into unidade_procedimentos (unidade_id, procedimento_id)
  values (p_unidade, p_procedimento) on conflict do nothing;

  for d in select distinct x from unnest(p_datas) as x order by 1 loop
    if d < current_date - 1 or exists (
         select 1 from vagas where unidade_executante_id = p_unidade and procedimento_id = p_procedimento
                               and data = d and profissional is not distinct from v_prof) then
      ignoradas := ignoradas || d; continue;
    end if;
    ndias := ndias + 1;
    for t in select * from jsonb_array_elements(p_turnos) loop
      hi := (t->>'hora_ini')::time; hf := (t->>'hora_fim')::time;
      itv := coalesce((t->>'intervalo')::int, 0); qtd := coalesce((t->>'qtd')::int, 1);
      if itv = 0 then
        for k in 1 .. qtd loop
          insert into vagas (unidade_executante_id, procedimento_id, profissional, data, hora) values (p_unidade, p_procedimento, v_prof, d, hi);
          n := n + 1;
        end loop;
      else
        for m in 0 .. (extract(epoch from (hf - hi)) / 60)::int - 1 by itv loop
          for k in 1 .. qtd loop
            insert into vagas (unidade_executante_id, procedimento_id, profissional, data, hora)
            values (p_unidade, p_procedimento, v_prof, d, hi + make_interval(mins => m));
            n := n + 1;
          end loop;
        end loop;
      end if;
    end loop;
  end loop;
  return jsonb_build_object('vagas', n, 'datas', ndias, 'ignoradas', to_jsonb(ignoradas));
end $$;

-- ---------------------------------------------------------------------
-- 6. VIEW PRINCIPAL (respeita as permissões de quem consulta)
-- ---------------------------------------------------------------------
drop view if exists vw_solicitacoes;
create view vw_solicitacoes with (security_invoker = true) as
select
  s.*,
  p.nome            as paciente_nome,
  p.nome_social     as paciente_nome_social,
  p.cns             as paciente_cns,
  p.cpf             as paciente_cpf,
  p.data_nascimento as paciente_nascimento,
  p.sexo            as paciente_sexo,
  p.telefone        as paciente_telefone,
  p.telefone2       as paciente_telefone2,
  p.nome_mae        as paciente_mae,
  concat_ws(', ', nullif(p.logradouro,''), nullif(p.numero,''), nullif(p.complemento,''),
            nullif(p.bairro,''), nullif(concat_ws('/', nullif(p.cidade,''), nullif(p.uf,'')),'')) as paciente_endereco,
  pr.nome           as procedimento_nome,
  pr.exige_regulacao,
  pr.codigo_sigtap  as procedimento_codigo,
  pr.tipo           as procedimento_tipo,
  pr.especialidade,
  u.nome            as unidade_solicitante_nome,
  uo.nome           as unidade_origem_nome,
  v.data            as vaga_data,
  v.hora            as vaga_hora,
  v.profissional    as vaga_profissional,
  v.unidade_executante_id,
  ue.nome           as unidade_executante_nome,
  ue.endereco       as unidade_executante_endereco,
  ue.telefone       as unidade_executante_telefone,
  rg.nome           as regulador_nome,
  cf.nome           as confirmado_por_nome,
  (current_date - s.created_at::date) as dias_espera,
  case s.prioridade when 'vermelho' then 1 when 'amarelo' then 2
                    when 'verde' then 3 else 4 end as peso_prioridade
from solicitacoes s
join pacientes     p  on p.id  = s.paciente_id
join procedimentos pr on pr.id = s.procedimento_id
join unidades      u  on u.id  = s.unidade_solicitante_id
left join unidades uo on uo.id = s.unidade_origem_id
left join vagas    v  on v.id  = s.vaga_id
left join unidades ue on ue.id = v.unidade_executante_id
left join perfis   rg on rg.id = s.regulador_id
left join perfis   cf on cf.id = s.confirmado_por;

grant select on vw_solicitacoes to authenticated;
grant usage, select on sequence protocolo_seq to authenticated;

-- ---------------------------------------------------------------------
-- 7. SEGURANÇA (RLS)
-- ---------------------------------------------------------------------
alter table unidades              enable row level security;
alter table perfis                enable row level security;
alter table procedimentos         enable row level security;
alter table unidade_procedimentos enable row level security;
alter table pacientes             enable row level security;
alter table vagas                 enable row level security;
alter table solicitacoes          enable row level security;
alter table historico             enable row level security;

do $$ declare r record; begin
  for r in select policyname, tablename from pg_policies
           where schemaname = 'public'
             and tablename in ('unidades','perfis','procedimentos','unidade_procedimentos',
                               'pacientes','vagas','solicitacoes','historico')
  loop
    execute format('drop policy %I on %I', r.policyname, r.tablename);
  end loop;
end $$;

-- Locais, procedimentos e vínculo: todos leem; admin/agendador gerenciam
create policy uni_sel on unidades for select to authenticated using (tem_papel('admin','regulador','agendador','solicitante','executante'));
create policy uni_mng on unidades for all to authenticated
  using (tem_papel('admin','agendador','regulador')) with check (tem_papel('admin','agendador','regulador'));

create policy pro_sel on procedimentos for select to authenticated using (tem_papel('admin','regulador','agendador','solicitante','executante'));
create policy pro_mng on procedimentos for all to authenticated
  using (tem_papel('admin','agendador','regulador')) with check (tem_papel('admin','agendador','regulador'));

create policy up_sel on unidade_procedimentos for select to authenticated using (tem_papel('admin','regulador','agendador','solicitante','executante'));
create policy up_mng on unidade_procedimentos for all to authenticated
  using (tem_papel('admin','agendador','regulador')) with check (tem_papel('admin','agendador','regulador'));

-- Perfis: todos leem (nomes), só admin altera
create policy per_sel on perfis for select to authenticated using (id=auth.uid() or tem_papel('admin'));
create policy per_upd on perfis for update to authenticated using (tem_papel('admin')) with check (tem_papel('admin'));

-- Pacientes
create policy pac_sel on pacientes for select to authenticated
  using (tem_papel('admin','regulador','agendador') or (tem_papel('solicitante') and (unidade_referencia_id=minha_unidade() or created_by=auth.uid())) or exists (select 1 from solicitacoes s where s.paciente_id=pacientes.id));
create policy pac_ins on pacientes for insert to authenticated
  with check (tem_papel('admin','regulador','agendador','solicitante'));
create policy pac_upd on pacientes for update to authenticated
  using (tem_papel('admin','regulador','agendador') or (tem_papel('solicitante') and (unidade_referencia_id=minha_unidade() or created_by=auth.uid())));
create policy pac_del on pacientes for delete to authenticated using (tem_papel('admin'));

-- Vagas
create policy vag_sel on vagas for select to authenticated using (tem_papel('admin','regulador','agendador','solicitante') or (tem_papel('executante') and unidade_executante_id=minha_unidade()));
create policy vag_mng on vagas for all to authenticated
  using (tem_papel('admin','agendador','regulador')) with check (tem_papel('admin','agendador','regulador'));

-- Solicitações: central vê tudo; atendente vê as da sua unidade; executante vê as agendadas no seu local
create policy sol_sel on solicitacoes for select to authenticated using (
  tem_papel('admin','regulador','agendador')
  or (tem_papel('solicitante') and unidade_solicitante_id = minha_unidade())
  or (tem_papel('executante') and exists (
        select 1 from vagas v where v.id = solicitacoes.vaga_id and coalesce(v.unidade_executante_id = minha_unidade(),false)))
);
create policy sol_ins on solicitacoes for insert to authenticated with check (
  status = 'pendente' and regulador_id is null and vaga_id is null and numero_guia is null and
  ( tem_papel('admin','regulador','agendador')
    or (tem_papel('solicitante') and unidade_solicitante_id = minha_unidade()) )
);
create policy sol_upd on solicitacoes for update to authenticated using (tem_papel('admin')) with check (tem_papel('admin'));

create policy his_sel on historico for select to authenticated using (
  exists (select 1 from solicitacoes s where s.id = historico.solicitacao_id)
);

-- ---------------------------------------------------------------------

do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'perfil_unidade_obrigatoria' and conrelid = 'public.perfis'::regclass) then
    alter table perfis add constraint perfil_unidade_obrigatoria check (not ativo or papel::text not in ('solicitante','executante') or unidade_id is not null);
  end if;
end $$;
revoke all on table perfis from anon,authenticated;
grant select on perfis to authenticated;
grant update(nome,papel,unidade_id,ativo) on perfis to authenticated;
create or replace function proteger_proprio_acesso() returns trigger language plpgsql as $$
begin
 if old.id=auth.uid() and (new.papel<>old.papel or not new.ativo) then raise exception 'Outro administrador precisa alterar seu acesso'; end if;
 return new;
end $$;
drop trigger if exists protege_admin on perfis;
create trigger protege_admin before update on perfis for each row execute function proteger_proprio_acesso();
-- Privilégios explícitos do cliente. As políticas acima limitam cada operação.
revoke all on unidades, procedimentos, unidade_procedimentos, pacientes, vagas, solicitacoes, historico, vw_solicitacoes from anon, authenticated;
grant select on unidades, procedimentos, unidade_procedimentos, pacientes, vagas, solicitacoes, historico, vw_solicitacoes to authenticated;
grant insert,update,delete on unidades,procedimentos,unidade_procedimentos,pacientes,vagas to authenticated;
grant insert,update on solicitacoes to authenticated;
revoke all on function gerar_guia() from public, anon, authenticated;
do $$
declare fn regprocedure;
begin
 for fn in select p.oid::regprocedure from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where n.nspname='public' and p.proname in ('agendar','confirmar_atendimento','registrar_desfecho','consultar_guia','regular_solicitacao','reenviar_solicitacao','gerar_vagas','tem_papel','minha_unidade','gerar_protocolo')
 loop
   execute format('revoke all on function %s from public, anon',fn);
   execute format('grant execute on function %s to authenticated',fn);
 end loop;
end $$;


-- ---------------------------------------------------------------------
-- 8. VALIDAÇÃO DE DOCUMENTOS E LOG DE ERRO
--    Este bloco é idêntico ao de banco-de-dados/migracoes/001-validacao-e-log-de-erros.sql,
--    que é o que se aplica em banco já existente. O CI confere que os dois
--    seguem iguais (ferramentas/verificar-migracoes.mjs), então edite um e
--    copie para o outro.
-- ---------------------------------------------------------------------
-- MIGRACAO-001-INICIO

-- ---------------------------------------------------------------------
--  Validação de CPF e de Cartão SUS
--  O cliente já valida em js/util.js, mas validação só no navegador não
--  vale nada: uma chamada direta à API REST com a chave publishable
--  gravaria 11 dígitos quaisquer. Aqui a regra passa a valer para
--  qualquer caminho de escrita.
--  Se mudar a regra aqui, mude também em js/util.js.
-- ---------------------------------------------------------------------
create or replace function valida_cpf(p text) returns boolean
language plpgsql immutable as $$
declare v text; s int; d int;
begin
  v := regexp_replace(coalesce(p, ''), '\D', '', 'g');
  if length(v) <> 11 then return false; end if;
  if v ~ '^(.)\1+$' then return false; end if;      -- 00000000000, 11111111111, ...
  for t in 9..10 loop
    s := 0;
    for i in 1..t loop
      s := s + substr(v, i, 1)::int * (t + 2 - i);
    end loop;
    d := ((s * 10) % 11) % 10;
    if d <> substr(v, t + 1, 1)::int then return false; end if;
  end loop;
  return true;
end $$;

create or replace function valida_cns(p text) returns boolean
language plpgsql immutable as $$
declare v text; s int := 0;
begin
  v := regexp_replace(coalesce(p, ''), '\D', '', 'g');
  if length(v) <> 15 then return false; end if;
  if substr(v, 1, 1) not in ('1','2','7','8','9') then return false; end if;
  for i in 1..15 loop
    s := s + substr(v, i, 1)::int * (16 - i);
  end loop;
  return s % 11 = 0;
end $$;

-- As restrições entram como NOT VALID: linhas já gravadas não são
-- reexaminadas, então a migração não falha num banco com cadastro antigo
-- irregular. Toda inserção e toda atualização a partir de agora passa pela
-- checagem. Depois de corrigir o cadastro histórico, se quiser fechar o
-- cerco, rode:
--   alter table pacientes validate constraint pacientes_cpf_valido;
--   alter table pacientes validate constraint pacientes_cns_valido;
-- Para achar o que está irregular:
--   select id, nome, cpf, cns from pacientes
--    where (cpf is not null and not (cpf ~ '^[0-9]{11}$' and valida_cpf(cpf)))
--       or (cns is not null and not (cns ~ '^[0-9]{15}$' and valida_cns(cns)));
alter table pacientes drop constraint if exists pacientes_cpf_valido;
alter table pacientes add constraint pacientes_cpf_valido
  check (cpf is null or (cpf ~ '^[0-9]{11}$' and valida_cpf(cpf))) not valid;

alter table pacientes drop constraint if exists pacientes_cns_valido;
alter table pacientes add constraint pacientes_cns_valido
  check (cns is null or (cns ~ '^[0-9]{15}$' and valida_cns(cns))) not valid;

-- ---------------------------------------------------------------------
--  Log de erro do navegador
--  Não há console aberto na recepção da unidade: sem isto, "deu erro
--  aqui" não tem como ser investigado. Guarda só o necessário para
--  diagnóstico — nunca dado de paciente. O cliente já mascara sequências
--  de 6 dígitos ou mais antes de enviar, porque mensagem de erro do
--  Postgres pode trazer o valor que violou a restrição.
-- ---------------------------------------------------------------------
create table if not exists erros (
  id         bigint generated always as identity primary key,
  usuario_id uuid references auth.users(id) on delete set null,
  onde       text,
  mensagem   text,
  pilha      text,
  rota       text,
  agente     text,
  created_at timestamptz not null default now()
);
create index if not exists erros_data_idx on erros (created_at desc);

alter table erros enable row level security;
revoke all on erros from anon, authenticated;
grant select on erros to authenticated;   -- a política abaixo restringe a admin
drop policy if exists err_sel on erros;
create policy err_sel on erros for select to authenticated using (tem_papel('admin'));

-- Sem grant de insert: a escrita passa só por registrar_erro(), que é
-- security definer e aplica o limite de volume.
create or replace function registrar_erro(
  p_onde text, p_mensagem text, p_pilha text default null,
  p_rota text default null, p_agente text default null)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then return; end if;
  -- Trava de volume: um laço de erro no navegador escreveria milhares de
  -- linhas por minuto. Vinte por usuário por hora bastam para diagnóstico.
  if (select count(*) from erros
        where usuario_id = auth.uid() and created_at > now() - interval '1 hour') >= 20 then
    return;
  end if;
  insert into erros (usuario_id, onde, mensagem, pilha, rota, agente)
  values (auth.uid(), left(p_onde, 120), left(p_mensagem, 500),
          left(p_pilha, 2000), left(p_rota, 200), left(p_agente, 300));
end $$;

-- Retenção. Log de erro não tem por que ser eterno. Chame periodicamente
-- (pg_cron, ou manualmente no SQL Editor de vez em quando).
create or replace function limpar_erros_antigos(p_dias int default 90)
returns integer
language plpgsql security definer set search_path = public as $$
declare n integer;
begin
  if not tem_papel('admin') then
    raise exception 'Apenas administrador pode limpar o log de erro.';
  end if;
  delete from erros where created_at < now() - make_interval(days => p_dias);
  get diagnostics n = row_count;
  return n;
end $$;

do $$
declare fn regprocedure;
begin
 for fn in select p.oid::regprocedure from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public' and p.proname in ('registrar_erro','limpar_erros_antigos','valida_cpf','valida_cns')
 loop
   execute format('revoke all on function %s from public, anon', fn);
   execute format('grant execute on function %s to authenticated', fn);
 end loop;
end $$;

-- MIGRACAO-001-FIM


-- ---------------------------------------------------------------------
-- 9. AUDITORIA, CORREÇÕES DE FLUXO, VULNERABILIDADE E TRANSPARÊNCIA
--    Bloco idêntico ao de banco-de-dados/migracoes/002-auditoria-fluxo-e-transparencia.sql.
--    O CI confere que seguem iguais (ferramentas/verificar-migracoes.mjs).
--    Recria vw_solicitacoes: a definição da seção 6 fica superada por esta.
-- ---------------------------------------------------------------------
-- MIGRACAO-002-INICIO

-- ---------------------------------------------------------------------
--  1. AUDITORIA DA RECLASSIFICAÇÃO DE RISCO E DA JUSTIFICATIVA
--
--  Reclassificar risco é o ato mais consequente que um regulador
--  pratica: move um paciente na frente de outros. Até aqui a prioridade
--  era sobrescrita em regular_solicitacao e o histórico só registrava
--  mudança de status, então não restava nenhum vestígio de qual era o
--  risco antes nem de quem o mudou. O mesmo valia para a justificativa
--  clínica, apagada pelo reenvio depois de uma devolução.
-- ---------------------------------------------------------------------
alter table historico
  add column if not exists prioridade_anterior    prioridade_risco,
  add column if not exists prioridade_nova        prioridade_risco,
  add column if not exists justificativa_anterior text;

create or replace function log_solicitacao() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_obs    text := nullif(current_setting('regula.obs', true), '');
  v_status boolean;
  v_prio   boolean;
  v_just   boolean;
begin
  if tg_op = 'INSERT' then
    insert into historico (solicitacao_id, status_novo, prioridade_nova, observacao, usuario_id)
    values (new.id, new.status, new.prioridade, 'Solicitação registrada', auth.uid());
    return new;
  end if;

  v_status := new.status is distinct from old.status or new.vaga_id is distinct from old.vaga_id;
  v_prio   := new.prioridade is distinct from old.prioridade;
  v_just   := new.justificativa is distinct from old.justificativa;

  if v_status or v_prio or v_just then
    insert into historico (
      solicitacao_id, status_anterior, status_novo,
      prioridade_anterior, prioridade_nova, justificativa_anterior,
      observacao, usuario_id)
    values (
      new.id, old.status, new.status,
      case when v_prio then old.prioridade end,
      case when v_prio then new.prioridade end,
      case when v_just then old.justificativa end,
      coalesce(v_obs, new.parecer), auth.uid());
  end if;
  return new;
end $$;

-- ---------------------------------------------------------------------
--  2. REVISÃO DA AUTORIZAÇÃO
--
--  regular_solicitacao só aceitava status 'pendente'. Autorização
--  equivocada não tinha volta: a única saída era cancelar, o que encerra
--  a solicitação e tira o paciente da fila. Agora o regulador pode rever
--  uma autorização que ainda não virou agendamento, com parecer
--  obrigatório. Depois de agendada, é preciso cancelar o agendamento
--  primeiro — a vaga já está comprometida com este paciente.
-- ---------------------------------------------------------------------
create or replace function regular_solicitacao(
  p_id bigint, p_acao text, p_prioridade prioridade_risco default null, p_parecer text default null
) returns void
language plpgsql security definer set search_path = public as $$
declare s solicitacoes; v_revisao boolean;
begin
  if not tem_papel('admin','regulador') then
    raise exception 'Apenas reguladores podem regular solicitações';
  end if;
  if p_acao not in ('autorizar','devolver','negar') then
    raise exception 'Ação inválida: %', p_acao;
  end if;
  select * into s from solicitacoes where id = p_id for update;
  if not found then raise exception 'Solicitação não encontrada'; end if;

  if s.status not in ('pendente','autorizada') then
    raise exception 'A solicitação não está em análise (status atual: %)', s.status;
  end if;
  v_revisao := s.status = 'autorizada';
  if v_revisao and s.vaga_id is not null then
    raise exception 'Esta solicitação já tem vaga marcada: cancele o agendamento antes de rever a autorização';
  end if;
  if v_revisao and coalesce(trim(p_parecer), '') = '' then
    raise exception 'Informe no parecer o motivo da revisão desta autorização';
  end if;
  if p_acao in ('devolver','negar') and coalesce(trim(p_parecer), '') = '' then
    raise exception 'Informe o motivo no parecer';
  end if;

  -- O trigger registra a mudança de prioridade com o valor anterior; esta
  -- observação diz em que ato ela aconteceu.
  perform set_config('regula.obs',
    case when v_revisao then 'Autorização revista pelo regulador' else null end, true);

  update solicitacoes set
    status         = case p_acao when 'autorizar' then 'autorizada'
                                 when 'devolver'  then 'devolvida'
                                 else 'negada' end::status_solicitacao,
    prioridade     = coalesce(p_prioridade, prioridade),
    parecer        = nullif(trim(p_parecer), ''),
    regulador_id   = auth.uid(),
    data_regulacao = now()
  where id = p_id;
end $$;

-- ---------------------------------------------------------------------
--  3. REENVIO PRESERVANDO A JUSTIFICATIVA ANTERIOR
--
--  O trigger acima já grava justificativa_anterior sempre que o texto
--  muda, então o regulador passa a conseguir comparar a versão recusada
--  com a corrigida. Aqui só melhoramos a observação do histórico.
-- ---------------------------------------------------------------------
create or replace function reenviar_solicitacao(p_id bigint, p_justificativa text)
returns void
language plpgsql security definer set search_path = public as $$
declare s solicitacoes;
begin
  select * into s from solicitacoes where id = p_id for update;
  if not found then raise exception 'Solicitação não encontrada'; end if;
  if not (tem_papel('admin','regulador') or (tem_papel('solicitante') and coalesce(s.unidade_solicitante_id = minha_unidade(),false))) then
    raise exception 'Sem permissão para reenviar esta solicitação';
  end if;
  if s.status <> 'devolvida' then raise exception 'Somente solicitações devolvidas podem ser reenviadas'; end if;
  if coalesce(trim(p_justificativa), '') = '' then
    raise exception 'Informe a justificativa clínica corrigida';
  end if;
  perform set_config('regula.obs', 'Reenviada pela unidade após correção', true);
  update solicitacoes set status = 'pendente', justificativa = trim(p_justificativa) where id = p_id;
end $$;

-- ---------------------------------------------------------------------
--  4. REAGENDAMENTO APÓS FALTA
--
--  'faltou' era terminal: agendar() recusava a solicitação e a única
--  saída oferecida na tela era abrir uma solicitação nova, o que perde o
--  vínculo com o pedido original e zera o tempo de fila acumulado. Agora
--  a mesma solicitação pode ser reagendada, com motivo obrigatório. A
--  vaga perdida não é liberada de propósito: ela foi consumida pela
--  falta e isso tem de continuar aparecendo nos indicadores.
-- ---------------------------------------------------------------------
drop function if exists agendar(bigint, bigint);
create or replace function agendar(p_solicitacao bigint, p_vaga bigint, p_obs text default null)
returns text
language plpgsql security definer set search_path = public as $$
declare s solicitacoes; v vagas; v_guia text; remarcar boolean; apos_falta boolean;
begin
  select * into s from solicitacoes where id = p_solicitacao for update;
  if not found then raise exception 'Solicitação não encontrada'; end if;
  if not (tem_papel('admin','regulador','agendador')
          or (tem_papel('solicitante') and coalesce(s.unidade_solicitante_id = minha_unidade(),false))) then
    raise exception 'Sem permissão para agendar';
  end if;
  if s.status not in ('pendente','autorizada','agendada','faltou') then
    raise exception 'Esta solicitação não pode ser agendada (status: %)', s.status;
  end if;
  if s.status = 'pendente' and exists (select 1 from procedimentos where id = s.procedimento_id and exige_regulacao) then
    raise exception 'Este procedimento exige regulação: a solicitação precisa ser autorizada pelo regulador antes do agendamento';
  end if;
  apos_falta := s.status = 'faltou';
  if apos_falta and coalesce(trim(p_obs), '') = '' then
    raise exception 'Informe o motivo do reagendamento após a falta';
  end if;
  remarcar := s.status = 'agendada';

  select * into v from vagas where id = p_vaga for update;
  if not found or v.status <> 'livre' then raise exception 'Vaga indisponível — escolha outro horário'; end if;
  if v.procedimento_id <> s.procedimento_id then raise exception 'A vaga é de outro procedimento'; end if;
  if v.data < current_date - 1 then raise exception 'A vaga está em data passada'; end if;

  if remarcar and s.vaga_id is not null then
    update vagas set status = 'livre' where id = s.vaga_id;
  end if;
  update vagas set status = 'ocupada' where id = p_vaga;

  v_guia := coalesce(s.numero_guia, gerar_guia());
  perform set_config('regula.obs',
    case when apos_falta then 'Reagendado após falta' when remarcar then 'Remarcado' else 'Agendado' end || ' para ' ||
    to_char(v.data, 'DD/MM/YYYY') || ' às ' || to_char(v.hora, 'HH24:MI') ||
    ' — ' || (select nome from unidades where id = v.unidade_executante_id) || ' — Guia ' || v_guia ||
    coalesce(' — ' || nullif(trim(p_obs), ''), ''), true);

  update solicitacoes set
    status = 'agendada', vaga_id = p_vaga, numero_guia = v_guia, data_agendamento = now(),
    -- limpa o desfecho anterior, senão a falta antiga fica grudada na solicitação
    data_execucao  = case when apos_falta then null else data_execucao end,
    confirmado_por = case when apos_falta then null else confirmado_por end,
    obs_execucao   = case when apos_falta then null else obs_execucao end
  where id = p_solicitacao;
  return v_guia;
end $$;

-- ---------------------------------------------------------------------
--  5. CRITÉRIOS DE VULNERABILIDADE
--
--  A PNR-SUS manda a prioridade considerar risco, tempo de espera e
--  vulnerabilidade, e atribui ao município definir os critérios a partir
--  de dados epidemiológicos, socioculturais e geográficos.
--
--  Então o software traz o mecanismo e nenhum critério: a tabela nasce
--  vazia, como CRITERIOS_RISCO já nascia. Enquanto o município não
--  cadastrar nada, o peso é zero e a ordenação da fila não muda. Quem
--  define o que é vulnerabilidade aqui é a regulação municipal, não o
--  programa.
-- ---------------------------------------------------------------------
create table if not exists criterios_vulnerabilidade (
  id         bigint generated always as identity primary key,
  nome       text not null unique,
  descricao  text,
  peso       int  not null default 1 check (peso between 1 and 10),
  ativo      boolean not null default true,
  created_at timestamptz not null default now()
);

create table if not exists solicitacao_vulnerabilidade (
  solicitacao_id bigint not null references solicitacoes(id) on delete cascade,
  criterio_id    bigint not null references criterios_vulnerabilidade(id) on delete restrict,
  registrado_por uuid default auth.uid() references perfis(id) on delete set null,
  created_at     timestamptz not null default now(),
  primary key (solicitacao_id, criterio_id)
);

alter table criterios_vulnerabilidade   enable row level security;
alter table solicitacao_vulnerabilidade enable row level security;
revoke all on criterios_vulnerabilidade, solicitacao_vulnerabilidade from anon, authenticated;
grant select on criterios_vulnerabilidade, solicitacao_vulnerabilidade to authenticated;
grant insert, update, delete on criterios_vulnerabilidade to authenticated;
grant insert, delete on solicitacao_vulnerabilidade to authenticated;

drop policy if exists cv_sel on criterios_vulnerabilidade;
create policy cv_sel on criterios_vulnerabilidade for select to authenticated
  using (tem_papel('admin','regulador','agendador','solicitante','executante'));
drop policy if exists cv_mng on criterios_vulnerabilidade;
create policy cv_mng on criterios_vulnerabilidade for all to authenticated
  using (tem_papel('admin')) with check (tem_papel('admin'));

-- Quem vê a solicitação vê as vulnerabilidades dela; registrar e remover
-- fica com a central e com a unidade de origem, nunca com o executante.
drop policy if exists sv_sel on solicitacao_vulnerabilidade;
create policy sv_sel on solicitacao_vulnerabilidade for select to authenticated
  using (exists (select 1 from solicitacoes s where s.id = solicitacao_vulnerabilidade.solicitacao_id));
drop policy if exists sv_ins on solicitacao_vulnerabilidade;
create policy sv_ins on solicitacao_vulnerabilidade for insert to authenticated
  with check (tem_papel('admin','regulador','agendador')
    or (tem_papel('solicitante') and exists (
          select 1 from solicitacoes s where s.id = solicitacao_vulnerabilidade.solicitacao_id
            and s.unidade_solicitante_id = minha_unidade())));
drop policy if exists sv_del on solicitacao_vulnerabilidade;
create policy sv_del on solicitacao_vulnerabilidade for delete to authenticated
  using (tem_papel('admin','regulador','agendador'));

-- ---------------------------------------------------------------------
--  6. VIEW PRINCIPAL — as duas esperas
--
--  dias_espera continua contando de created_at, a data em que a
--  solicitação foi lançada no sistema: é o que ordena a fila hoje e
--  mudar isso reordenaria pacientes reais retroativamente, decisão da
--  regulação e não do software.
--
--  O que entra são duas medidas que faltavam:
--    dias_desde_pedido  — espera real do paciente, desde o pedido médico
--    dias_ate_insercao  — quanto a unidade demorou para lançar o pedido
--
--  A diferença entre dias_desde_pedido e dias_espera é tempo que o
--  paciente esperou e que a fila não conta. Agora dá para medir.
-- ---------------------------------------------------------------------
drop view if exists vw_solicitacoes;
create view vw_solicitacoes with (security_invoker = true) as
select
  s.*,
  p.nome            as paciente_nome,
  p.nome_social     as paciente_nome_social,
  p.cns             as paciente_cns,
  p.cpf             as paciente_cpf,
  p.data_nascimento as paciente_nascimento,
  p.sexo            as paciente_sexo,
  p.telefone        as paciente_telefone,
  p.telefone2       as paciente_telefone2,
  p.nome_mae        as paciente_mae,
  concat_ws(', ', nullif(p.logradouro,''), nullif(p.numero,''), nullif(p.complemento,''),
            nullif(p.bairro,''), nullif(concat_ws('/', nullif(p.cidade,''), nullif(p.uf,'')),'')) as paciente_endereco,
  pr.nome           as procedimento_nome,
  pr.exige_regulacao,
  pr.codigo_sigtap  as procedimento_codigo,
  pr.tipo           as procedimento_tipo,
  pr.especialidade,
  u.nome            as unidade_solicitante_nome,
  uo.nome           as unidade_origem_nome,
  v.data            as vaga_data,
  v.hora            as vaga_hora,
  v.profissional    as vaga_profissional,
  v.unidade_executante_id,
  ue.nome           as unidade_executante_nome,
  ue.endereco       as unidade_executante_endereco,
  ue.telefone       as unidade_executante_telefone,
  rg.nome           as regulador_nome,
  cf.nome           as confirmado_por_nome,
  (current_date - s.created_at::date)                        as dias_espera,
  (current_date - s.data_pedido)                             as dias_desde_pedido,
  (s.created_at::date - s.data_pedido)                       as dias_ate_insercao,
  coalesce(vu.peso, 0)                                       as peso_vulnerabilidade,
  coalesce(vu.nomes, array[]::text[])                         as vulnerabilidades,
  case s.prioridade when 'vermelho' then 1 when 'amarelo' then 2
                    when 'verde' then 3 else 4 end as peso_prioridade
from solicitacoes s
join pacientes     p  on p.id  = s.paciente_id
join procedimentos pr on pr.id = s.procedimento_id
join unidades      u  on u.id  = s.unidade_solicitante_id
left join unidades uo on uo.id = s.unidade_origem_id
left join vagas    v  on v.id  = s.vaga_id
left join unidades ue on ue.id = v.unidade_executante_id
left join perfis   rg on rg.id = s.regulador_id
left join perfis   cf on cf.id = s.confirmado_por
left join lateral (
  select sum(c.peso) as peso, array_agg(c.nome order by c.nome) as nomes
    from solicitacao_vulnerabilidade sv
    join criterios_vulnerabilidade c on c.id = sv.criterio_id and c.ativo
   where sv.solicitacao_id = s.id
) vu on true;

grant select on vw_solicitacoes to authenticated;

-- ---------------------------------------------------------------------
--  7. ACOMPANHAMENTO PELO PACIENTE
--
--  A PNR-SUS exige que o usuário acompanhe a própria situação e que a
--  população veja as listas e os tempos médios, respeitada a LGPD.
--
--  Isto abre o primeiro caminho anônimo do banco, então vale explicitar
--  o que foi feito para não transformar transparência em vazamento:
--
--  - A função devolve situação, procedimento, posição na fila e, se já
--    agendada, data, hora e local. NÃO devolve nome, CPF, CNS, telefone
--    nem endereço do paciente — quem consulta já sabe quem é.
--  - Exige protocolo E data de nascimento. O protocolo é sequencial e
--    previsível, então ele sozinho não serve como segredo.
--  - Mesmo assim a data de nascimento é segredo fraco, então há trava de
--    volume: 10 tentativas por protocolo por hora e 60 no banco todo por
--    minuto, o que inviabiliza varredura. Toda tentativa é registrada.
--  - A mensagem de erro é a mesma para protocolo inexistente e para data
--    errada, para não confirmar a existência de um protocolo.
-- ---------------------------------------------------------------------
create table if not exists consultas_publicas (
  id         bigint generated always as identity primary key,
  protocolo  text not null,
  sucesso    boolean not null,
  created_at timestamptz not null default now()
);
create index if not exists consultas_publicas_prot_idx on consultas_publicas (protocolo, created_at desc);
create index if not exists consultas_publicas_data_idx on consultas_publicas (created_at desc);

alter table consultas_publicas enable row level security;
revoke all on consultas_publicas from anon, authenticated;
grant select on consultas_publicas to authenticated;
drop policy if exists cpub_sel on consultas_publicas;
create policy cpub_sel on consultas_publicas for select to authenticated using (tem_papel('admin'));
-- Sem grant de insert: só a função abaixo escreve, e ela aplica a trava.

drop function if exists consultar_protocolo(text, date);
create function consultar_protocolo(p_protocolo text, p_nascimento date)
returns table (
  resultado            text,   -- 'ok' | 'nao_encontrado' | 'limite' | 'incompleto'
  protocolo            text,
  situacao             text,
  exige_regulacao      boolean,
  procedimento         text,
  data_pedido          date,
  dias_desde_pedido    int,
  posicao              int,
  agendada_data        date,
  agendada_hora        time,
  local_nome           text,
  local_endereco       text,
  local_telefone       text,
  parecer              text
)
language plpgsql security definer set search_path = public as $$
declare
  v_prot  text := upper(regexp_replace(coalesce(p_protocolo, ''), '[^0-9A-Za-z]', '', 'g'));
  s       record;
  n_prot  int;
  n_geral int;
  v_pos   int;
begin
  -- Esta função devolve o erro como dado, em "resultado", e não com
  -- raise exception. O motivo é a trava de volume logo abaixo: raise
  -- desfaz a transação inteira, inclusive o insert que registra a
  -- tentativa, então o contador nunca subiria e a trava não existiria
  -- na prática. Testado: com raise, 12 tentativas passavam das 10.
  if v_prot = '' or p_nascimento is null then
    return query select 'incompleto'::text, null::text, null::text, null::boolean, null::text,
                        null::date, null::int, null::int, null::date, null::time,
                        null::text, null::text, null::text, null::text;
    return;
  end if;

  -- As colunas de retorno desta função (protocolo, situacao, ...) também são
  -- variáveis dentro do corpo, então toda coluna de tabela com nome igual
  -- precisa vir qualificada, ou o Postgres recusa por ambiguidade.
  select count(*) into n_prot  from consultas_publicas cp
   where cp.protocolo = v_prot and cp.created_at > now() - interval '1 hour';
  select count(*) into n_geral from consultas_publicas cp
   where cp.created_at > now() - interval '1 minute';

  if n_prot >= 10 or n_geral >= 60 then
    insert into consultas_publicas (protocolo, sucesso) values (v_prot, false);
    return query select 'limite'::text, null::text, null::text, null::boolean, null::text,
                        null::date, null::int, null::int, null::date, null::time,
                        null::text, null::text, null::text, null::text;
    return;
  end if;

  select sol.id, sol.protocolo, sol.status, sol.prioridade, sol.created_at, sol.data_pedido,
         sol.procedimento_id, sol.parecer, sol.vaga_id,
         pr.nome as proc_nome, pr.exige_regulacao,
         vg.data as vdata, vg.hora as vhora,
         ue.nome as uenome, ue.endereco as ueend, ue.telefone as uetel
    into s
    from solicitacoes sol
    join pacientes     pa on pa.id = sol.paciente_id
    join procedimentos pr on pr.id = sol.procedimento_id
    left join vagas    vg on vg.id = sol.vaga_id
    left join unidades ue on ue.id = vg.unidade_executante_id
   where sol.protocolo = v_prot
     and pa.data_nascimento = p_nascimento;

  if not found then
    insert into consultas_publicas (protocolo, sucesso) values (v_prot, false);
    -- Resposta idêntica para protocolo que não existe e para data que não
    -- confere. Distinguir os dois confirmaria a existência do protocolo.
    return query select 'nao_encontrado'::text, null::text, null::text, null::boolean, null::text,
                        null::date, null::int, null::int, null::date, null::time,
                        null::text, null::text, null::text, null::text;
    return;
  end if;

  insert into consultas_publicas (protocolo, sucesso) values (v_prot, true);

  if s.status in ('pendente','autorizada') then
    select count(*) + 1 into v_pos
      from solicitacoes o
     where o.procedimento_id = s.procedimento_id
       and o.status in ('pendente','autorizada')
       and (case o.prioridade when 'vermelho' then 1 when 'amarelo' then 2
                              when 'verde' then 3 else 4 end, o.created_at)
         < (case s.prioridade when 'vermelho' then 1 when 'amarelo' then 2
                              when 'verde' then 3 else 4 end, s.created_at);
  end if;

  return query select
    'ok'::text,
    s.protocolo,
    case s.status
      when 'pendente'   then case when s.exige_regulacao then 'Em análise pela regulação'
                                  else 'Aguardando marcação' end
      when 'autorizada' then 'Autorizada — aguardando vaga'
      when 'devolvida'  then 'Devolvida à unidade de origem para correção'
      when 'negada'     then 'Negada pela regulação'
      when 'agendada'   then 'Agendada'
      when 'realizada'  then 'Atendimento realizado'
      when 'faltou'     then 'Falta registrada'
      when 'cancelada'  then 'Cancelada'
      else s.status::text
    end,
    s.exige_regulacao,
    s.proc_nome,
    s.data_pedido,
    (current_date - s.data_pedido),
    v_pos,
    s.vdata, s.vhora, s.uenome, s.ueend, s.uetel,
    -- O motivo só vai quando o paciente precisa saber dele.
    case when s.status in ('devolvida','negada') then s.parecer end;
end $$;

-- ---------------------------------------------------------------------
--  8. PAINEL PÚBLICO DE TEMPOS DE ESPERA
--  Dado agregado por procedimento, sem nada pessoal.
-- ---------------------------------------------------------------------
create or replace function tempos_medios_espera()
returns table (
  procedimento      text,
  exige_regulacao   boolean,
  aguardando        bigint,
  espera_media_dias numeric,
  espera_maxima_dias int
)
language sql stable security definer set search_path = public as $$
  select pr.nome, pr.exige_regulacao, count(*),
         round(avg(current_date - coalesce(s.data_pedido, s.created_at::date)), 1),
         max(current_date - coalesce(s.data_pedido, s.created_at::date))
    from solicitacoes s
    join procedimentos pr on pr.id = s.procedimento_id
   where s.status in ('pendente','autorizada')
   group by pr.nome, pr.exige_regulacao
   order by count(*) desc, pr.nome
$$;

-- ---------------------------------------------------------------------
--  9. PERMISSÕES DAS FUNÇÕES
-- ---------------------------------------------------------------------
revoke all on function consultar_protocolo(text, date)  from public;
revoke all on function tempos_medios_espera()           from public;
grant execute on function consultar_protocolo(text, date) to anon, authenticated;
grant execute on function tempos_medios_espera()          to anon, authenticated;

do $$
declare fn regprocedure;
begin
 for fn in select p.oid::regprocedure from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public' and p.proname in ('agendar','regular_solicitacao','reenviar_solicitacao')
 loop
   execute format('revoke all on function %s from public, anon', fn);
   execute format('grant execute on function %s to authenticated', fn);
 end loop;
end $$;

-- MIGRACAO-002-FIM


-- ---------------------------------------------------------------------
-- 10. AUDITORIA DE PACIENTE, LOG DE ACESSO, MIRA E RETENÇÃO
--     Bloco idêntico ao de banco-de-dados/migracoes/003-auditoria-de-paciente-mira-e-retencao.sql.
--     O CI confere que seguem iguais (ferramentas/verificar-migracoes.mjs).
-- ---------------------------------------------------------------------
-- MIGRACAO-003-INICIO

-- ---------------------------------------------------------------------
--  1. AUDITORIA DO CADASTRO DE PACIENTE
--
--  O historico cobria só as solicitações. Alterar o nome, o CPF, o Cartão
--  SUS ou o telefone de um paciente não deixava rastro nenhum: nem quem
--  mudou, nem quando, nem qual era o valor antes. Num sistema de saúde
--  isso é o tipo de coisa de que ninguém sente falta até o dia em que um
--  cadastro "mudou sozinho".
--
--  O trigger compara o registro inteiro em jsonb e grava uma linha por
--  campo alterado. Ser genérico é de propósito: coluna nova passa a ser
--  auditada sozinha, sem ninguém precisar lembrar de incluí-la aqui.
-- ---------------------------------------------------------------------
create table if not exists historico_paciente (
  id             bigint generated always as identity primary key,
  paciente_id    bigint not null,
  operacao       text   not null check (operacao in ('alteracao','exclusao')),
  campo          text,
  valor_anterior text,
  valor_novo     text,
  usuario_id     uuid references perfis(id) on delete set null,
  created_at     timestamptz not null default now()
);
create index if not exists hist_pac_idx  on historico_paciente (paciente_id, created_at desc);
create index if not exists hist_pac_data on historico_paciente (created_at desc);

create or replace function log_paciente() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_antes jsonb; v_depois jsonb; k text;
begin
  if tg_op = 'DELETE' then
    insert into historico_paciente (paciente_id, operacao, valor_anterior, usuario_id)
    values (old.id, 'exclusao', to_jsonb(old)::text, auth.uid());
    return old;
  end if;

  v_antes  := to_jsonb(old);
  v_depois := to_jsonb(new);
  for k in select jsonb_object_keys(v_depois) loop
    -- created_at e created_by não mudam por edição; registrá-los seria ruído
    if k in ('id','created_at','created_by') then continue; end if;
    if v_antes -> k is distinct from v_depois -> k then
      insert into historico_paciente (paciente_id, operacao, campo, valor_anterior, valor_novo, usuario_id)
      values (new.id, 'alteracao', k, v_antes ->> k, v_depois ->> k, auth.uid());
    end if;
  end loop;
  return new;
end $$;

drop trigger if exists trg_pac_log on pacientes;
create trigger trg_pac_log after update or delete on pacientes
  for each row execute function log_paciente();

alter table historico_paciente enable row level security;
revoke all on historico_paciente from anon, authenticated;
grant select on historico_paciente to authenticated;
drop policy if exists hpac_sel on historico_paciente;
-- Quem audita é a administração. Nem a unidade que cadastrou o paciente
-- precisa ver o que outra unidade corrigiu nele.
create policy hpac_sel on historico_paciente for select to authenticated using (tem_papel('admin'));

-- ---------------------------------------------------------------------
--  2. LOG DE ACESSO AO CADASTRO DE PACIENTE
--
--  Diferente do item 1: ali é quem ALTEROU, aqui é quem OLHOU. A LGPD
--  trata dado de saúde como sensível e registro de acesso de leitura é o
--  que uma auditoria pede.
--
--  LIMITE IMPORTANTE, para ninguém confiar mais do que deve: o cliente lê
--  a tabela pacientes direto pelo PostgREST, então isto NÃO intercepta
--  toda consulta ao banco. Registra abertura deliberada de cadastro pela
--  aplicação — abrir a ficha, abrir o detalhe de uma solicitação, imprimir
--  guia. Interceptar toda leitura exigiria tirar o acesso direto à tabela
--  e passar tudo por função, o que é refatoração grande; está anotada
--  como pendência no README.
-- ---------------------------------------------------------------------
create table if not exists acessos_paciente (
  id          bigint generated always as identity primary key,
  paciente_id bigint not null references pacientes(id) on delete cascade,
  usuario_id  uuid references perfis(id) on delete set null,
  contexto    text,
  created_at  timestamptz not null default now()
);
create index if not exists acessos_pac_idx  on acessos_paciente (paciente_id, created_at desc);
create index if not exists acessos_usu_idx  on acessos_paciente (usuario_id, created_at desc);
create index if not exists acessos_data_idx on acessos_paciente (created_at desc);

alter table acessos_paciente enable row level security;
revoke all on acessos_paciente from anon, authenticated;
grant select on acessos_paciente to authenticated;
drop policy if exists apac_sel on acessos_paciente;
create policy apac_sel on acessos_paciente for select to authenticated using (tem_papel('admin'));
-- Sem grant de insert: só a função abaixo escreve.

create or replace function registrar_acesso_paciente(p_paciente_id bigint, p_contexto text default null)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null or p_paciente_id is null then return; end if;

  -- Deduplicação por janela. Sem isto, cada redesenho de tela viraria uma
  -- linha e o log ficaria impossível de ler — e um log ilegível não é
  -- auditoria, é só volume.
  if exists (
    select 1 from acessos_paciente
     where paciente_id = p_paciente_id
       and usuario_id = auth.uid()
       and coalesce(contexto, '') = coalesce(left(p_contexto, 60), '')
       and created_at > now() - interval '10 minutes'
  ) then
    return;
  end if;

  insert into acessos_paciente (paciente_id, usuario_id, contexto)
  values (p_paciente_id, auth.uid(), left(p_contexto, 60));
end $$;

-- ---------------------------------------------------------------------
--  3. EXPORTAÇÃO MIRA
--
--  A Portaria GM/MS nº 6.656/2025 tornou obrigatório o envio dos dados de
--  Regulação Assistencial ao Ministério, no formato do Modelo de
--  Informação da Regulação Assistencial (MIRA), instituído pela Portaria
--  Conjunta SAES/SEIDIGI nº 3/2023. Usar sistema próprio não dispensa: a
--  portaria prevê expressamente sistemas próprios como mecanismo de envio.
--
--  O QUE ESTA SEÇÃO FAZ: monta os 16 elementos do modelo a partir do
--  banco e aponta o que ainda impede o envio de cada registro.
--
--  O QUE ELA NÃO FAZ, e precisa ficar claro: não transmite para a RNDS.
--  A transmissão usa um Guia de Implementação FHIR (fhir.saude.gov.br/rira)
--  e exige credenciamento do município. A serialização FHIR e o envio
--  devem ser validados contra o guia oficial antes de qualquer uso real —
--  o que está aqui é a camada de dados, não o transporte.
--
--  Elementos do modelo, conforme o anexo da portaria:
--    Caracterização da regulação:  identificador do registro, status,
--      código do procedimento (SIGTAP), data da solicitação, data de
--      autorização, data da execução
--    Caracterização dos participantes: identificador do paciente (CPF ou
--      CNS), CNES do solicitante, do regulador e do executante,
--      especialidade do executante (CBO)
--    Caracterização da solicitação: modalidade assistencial, caráter,
--      motivo (CID-10)
-- ---------------------------------------------------------------------

-- Campos que o modelo exige e o schema não tinha.
alter table unidades
  add column if not exists reguladora boolean not null default false;
comment on column unidades.reguladora is
  'Marca a unidade que opera a central de regulação. O CNES dela vai no elemento "estabelecimento regulador" do MIRA.';

alter table procedimentos
  add column if not exists cbo         text,
  add column if not exists modalidade  text not null default 'ambulatorial'
    check (modalidade in ('ambulatorial','hospitalar'));
comment on column procedimentos.cbo is
  'Código CBO da especialidade do executante. O MIRA o exige para procedimentos dos grupos 03 e 04 da SIGTAP (regra RN03).';

/* Caráter da solicitação: o MIRA aceita Eletivo ou Urgência; aqui a
   classificação é de quatro níveis. O mapeamento fica isolado nesta
   função para a regulação municipal poder mudá-lo num lugar só, sem
   mexer na exportação. */
create or replace function mira_caracter(p prioridade_risco) returns text
language sql immutable as $$
  select case when p in ('vermelho','amarelo') then 'urgencia' else 'eletivo' end
$$;

/* Status: o modelo tem sete situações; o sistema tem oito. */
create or replace function mira_status(p status_solicitacao) returns text
language sql immutable as $$
  select case p
    when 'pendente'   then 'pendente'
    when 'autorizada' then 'pendente'            -- autorizada e ainda sem vaga
    when 'devolvida'  then 'devolvido_solicitante'
    when 'negada'     then 'negado_cancelado'
    when 'cancelada'  then 'negado_cancelado'
    when 'agendada'   then 'agendado'
    when 'realizada'  then 'atendido'
    when 'faltou'     then 'falta'
  end
$$;

-- mira_lote devolve setof vw_mira, então depende da view: tem de sair
-- antes, ou a segunda execução desta migração falha ao derrubá-la.
drop function if exists mira_lote(date, date);
drop view if exists vw_mira;
create view vw_mira with (security_invoker = true) as
select
  -- Caracterização da regulação
  s.protocolo                                   as identificador_registro,
  mira_status(s.status)                         as status_solicitacao,
  pr.codigo_sigtap                              as codigo_procedimento,
  s.created_at                                  as data_solicitacao,
  s.data_regulacao                              as data_autorizacao,
  s.data_execucao                               as data_execucao,
  -- Caracterização dos participantes
  coalesce(p.cns, p.cpf)                        as identificador_paciente,
  case when p.cns is not null then 'cns' else 'cpf' end as tipo_identificador_paciente,
  us.cnes                                       as cnes_solicitante,
  (select u2.cnes from unidades u2 where u2.reguladora order by u2.id limit 1) as cnes_regulador,
  ue.cnes                                       as cnes_executante,
  pr.cbo                                        as cbo_executante,
  -- Caracterização da solicitação
  pr.modalidade                                 as modalidade_assistencial,
  mira_caracter(s.prioridade)                   as caracter_solicitacao,
  s.cid10                                       as motivo_solicitacao,
  -- apoio interno, fora do modelo
  s.id                                          as solicitacao_id,
  s.updated_at                                  as atualizado_em
from solicitacoes s
join pacientes     p  on p.id  = s.paciente_id
join procedimentos pr on pr.id = s.procedimento_id
join unidades      us on us.id = s.unidade_solicitante_id
left join vagas    v  on v.id  = s.vaga_id
left join unidades ue on ue.id = v.unidade_executante_id;

revoke all on vw_mira from anon, authenticated;

/* O que ainda impede o envio. Sem isto, descobrir que 300 solicitações
   não têm CID-10 aconteceria no meio da transmissão, e não antes. */
create or replace function mira_pendencias()
returns table (problema text, solicitacoes bigint, como_resolver text)
language sql stable security definer set search_path = public as $$
  select * from (
    select 'Solicitação sem CID-10'::text, count(*),
           'O MIRA exige o motivo da solicitação em CID-10. Preencha na solicitação.'::text
      from solicitacoes where coalesce(trim(cid10), '') = ''
    union all
    select 'Procedimento sem código SIGTAP', count(*),
           'O MIRA exige o código do procedimento. Preencha em Procedimentos.'
      from solicitacoes s join procedimentos pr on pr.id = s.procedimento_id
     where coalesce(trim(pr.codigo_sigtap), '') = ''
    union all
    select 'Unidade solicitante sem CNES', count(*),
           'O MIRA exige o CNES do estabelecimento solicitante. Preencha em Locais e unidades.'
      from solicitacoes s join unidades u on u.id = s.unidade_solicitante_id
     where coalesce(trim(u.cnes), '') = ''
    union all
    select 'Paciente sem CPF e sem Cartão SUS', count(*),
           'O MIRA identifica o paciente por CPF ou CNS. Complete o cadastro.'
      from solicitacoes s join pacientes p on p.id = s.paciente_id
     where coalesce(trim(p.cns), '') = '' and coalesce(trim(p.cpf), '') = ''
    union all
    select 'Nenhuma unidade marcada como reguladora', count(*),
           'Marque a unidade que opera a central em Locais e unidades: o CNES dela é o do estabelecimento regulador.'
      from solicitacoes
     where not exists (select 1 from unidades where reguladora)
  ) t(problema, solicitacoes, como_resolver)
  where t.solicitacoes > 0
  order by t.solicitacoes desc
$$;

/* Lote pronto para exportação, só com o que está completo. O intervalo é
   por data de atualização, para um reenvio pegar o que mudou. */
create or replace function mira_lote(p_de date default null, p_ate date default null)
returns setof vw_mira
language plpgsql stable security definer set search_path = public as $$
begin
  if not tem_papel('admin','regulador') then
    raise exception 'Acesso à exportação MIRA restrito à regulação.' using errcode = '42501';
  end if;
  return query
    select * from vw_mira
     where codigo_procedimento is not null
       and identificador_paciente is not null
       and cnes_solicitante is not null
       and motivo_solicitacao is not null
       and (p_de  is null or atualizado_em::date >= p_de)
       and (p_ate is null or atualizado_em::date <= p_ate)
     order by atualizado_em;
end
$$;

-- ---------------------------------------------------------------------
--  4. RETENÇÃO
--
--  Uma distinção que precisa ficar explícita: registro assistencial e log
--  operacional não seguem a mesma regra.
--
--  Solicitações, histórico e cadastro de paciente são registro de
--  atendimento em saúde e NÃO são apagados por esta função. O prazo de
--  guarda de prontuário é matéria de resolução do Conselho Federal de
--  Medicina e de legislação de arquivo público — decisão do município com
--  o jurídico, não do programa.
--
--  O que esta função limpa é só log operacional: erro de navegador,
--  tentativa de consulta pública e log de acesso. Mesmo assim, os prazos
--  ficam numa tabela para o município ajustar sem mexer em código.
-- ---------------------------------------------------------------------
create table if not exists politica_retencao (
  tabela     text primary key,
  dias       int  not null check (dias >= 1),
  descricao  text
);

insert into politica_retencao (tabela, dias, descricao) values
  ('erros',              90,  'Log de erro do navegador. Serve para diagnóstico recente.'),
  ('consultas_publicas', 180, 'Tentativas de consulta pública. Prazo maior porque é o que evidencia tentativa de varredura.'),
  ('acessos_paciente',   730, 'Log de acesso a cadastro de paciente. Prazo longo de propósito: é registro de auditoria da LGPD.')
on conflict (tabela) do nothing;

alter table politica_retencao enable row level security;
revoke all on politica_retencao from anon, authenticated;
grant select on politica_retencao to authenticated;
grant update (dias, descricao) on politica_retencao to authenticated;
drop policy if exists ret_sel on politica_retencao;
create policy ret_sel on politica_retencao for select to authenticated using (tem_papel('admin'));
drop policy if exists ret_upd on politica_retencao;
create policy ret_upd on politica_retencao for update to authenticated
  using (tem_papel('admin')) with check (tem_papel('admin'));

create or replace function aplicar_retencao()
returns table (tabela text, apagados bigint)
language plpgsql security definer set search_path = public as $$
declare r record; n bigint;
begin
  if not tem_papel('admin') then
    raise exception 'Apenas administrador pode aplicar a retenção.';
  end if;
  for r in select * from politica_retencao order by tabela loop
    -- Lista fixa de propósito: nome de tabela vindo de dado, montado em
    -- SQL dinâmico, é injeção esperando acontecer.
    if r.tabela not in ('erros','consultas_publicas','acessos_paciente') then continue; end if;
    execute format('delete from %I where created_at < now() - make_interval(days => $1)', r.tabela)
      using r.dias;
    get diagnostics n = row_count;
    tabela := r.tabela; apagados := n; return next;
  end loop;
end $$;

-- ---------------------------------------------------------------------
--  5. PERMISSÕES DAS FUNÇÕES NOVAS
-- ---------------------------------------------------------------------
do $$
declare fn regprocedure;
begin
 for fn in select p.oid::regprocedure from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public' and p.proname in
   ('registrar_acesso_paciente','mira_pendencias','mira_lote','mira_status','mira_caracter','aplicar_retencao')
 loop
   execute format('revoke all on function %s from public, anon', fn);
   execute format('grant execute on function %s to authenticated', fn);
 end loop;
end $$;

-- MIGRACAO-003-FIM


-- ---------------------------------------------------------------------
-- 11. CADASTRO DE PROFISSIONAIS EXECUTANTES
--     Bloco idêntico ao de banco-de-dados/migracoes/004-cadastro-de-profissionais.sql.
--     Recria gerar_vagas e vw_mira: as definições anteriores ficam superadas.
-- ---------------------------------------------------------------------
-- MIGRACAO-004-INICIO

-- ---------------------------------------------------------------------
--  1. PROFISSIONAIS
--
--  Até aqui vagas.profissional era texto livre, e o autocompletar da tela
--  de agendas era montado a partir dos nomes já digitados — ou seja,
--  repetia junto os erros de digitação. "Dr. João Batista", "João B." e
--  "JOAO BATISTA FERREIRA" viravam três profissionais diferentes para
--  qualquer relatório.
--
--  O médico SOLICITANTE segue como texto livre de propósito: ele costuma
--  ser de fora da rede do município, às vezes de outro estado, e exigir
--  cadastro prévio travaria o registro da solicitação na recepção.
--
--  O CBO mora aqui, e não no procedimento, porque o elemento do MIRA é
--  "especialidade médica do executante" — é do profissional que executa,
--  não do procedimento. A coluna em procedimentos vira fallback.
-- ---------------------------------------------------------------------
create table if not exists profissionais (
  id              bigint generated always as identity primary key,
  nome            text not null,
  conselho        text not null default 'CRM'
                  check (conselho in ('CRM','COREN','CRO','CREFITO','CRP','CRN','CRFa','CRF','OUTRO')),
  numero_conselho text,
  uf_conselho     char(2),
  cbo             text,
  especialidade   text,
  unidade_id      bigint references unidades(id),
  ativo           boolean not null default true,
  created_at      timestamptz not null default now()
);

-- Um mesmo registro de conselho não pode aparecer duas vezes. Fica fora
-- do unique da tabela porque numero_conselho é opcional: profissional sem
-- número cadastrado não deve colidir com outro igualmente sem número.
create unique index if not exists profissionais_conselho_uniq
  on profissionais (conselho, upper(numero_conselho), upper(uf_conselho))
  where numero_conselho is not null and uf_conselho is not null;

create index if not exists profissionais_nome_idx on profissionais (lower(nome));

alter table vagas add column if not exists profissional_id bigint references profissionais(id);
create index if not exists vagas_prof_idx on vagas (profissional_id);
comment on column vagas.profissional is
  'Mantido para as vagas criadas antes do cadastro de profissionais. Em vaga nova vem de profissionais.nome, via profissional_id.';

alter table profissionais enable row level security;
revoke all on profissionais from anon, authenticated;
grant select on profissionais to authenticated;
grant insert, update, delete on profissionais to authenticated;

drop policy if exists prof_sel on profissionais;
create policy prof_sel on profissionais for select to authenticated
  using (tem_papel('admin','regulador','agendador','solicitante','executante'));
drop policy if exists prof_mng on profissionais;
create policy prof_mng on profissionais for all to authenticated
  using (tem_papel('admin','agendador','regulador'))
  with check (tem_papel('admin','agendador','regulador'));

-- ---------------------------------------------------------------------
--  2. GERAÇÃO DE VAGAS COM PROFISSIONAL CADASTRADO
-- ---------------------------------------------------------------------
-- A assinatura muda de text para bigint, então a versão antiga sai primeiro,
-- senão as duas coexistem como sobrecarga e a chamada fica ambígua.
drop function if exists gerar_vagas(bigint, bigint, text, date[], jsonb);
create or replace function gerar_vagas(
  p_unidade bigint, p_procedimento bigint, p_profissional bigint, p_datas date[], p_turnos jsonb
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  d date; t jsonb; m int; k int; n int := 0; ndias int := 0; ignoradas date[] := '{}';
  v_prof text; hi time; hf time; itv int; qtd int;
begin
  if not tem_papel('admin','agendador','regulador') then raise exception 'Sem permissão para gerar vagas'; end if;
  -- O nome é copiado para a vaga no momento da geração: se o profissional
  -- for renomeado depois, a guia já impressa continua batendo com o papel
  -- que o paciente tem na mão.
  if p_profissional is not null then
    select nome into v_prof from profissionais where id = p_profissional and ativo;
    if v_prof is null then raise exception 'Profissional não encontrado ou inativo'; end if;
  end if;
  if p_datas is null or cardinality(p_datas) = 0 then raise exception 'Nenhuma data informada'; end if;
  if cardinality(p_datas) > 400 then raise exception 'Máximo de 400 datas por vez'; end if;
  if p_turnos is null or jsonb_array_length(p_turnos) = 0 then raise exception 'Informe pelo menos um turno'; end if;

  for t in select * from jsonb_array_elements(p_turnos) loop
    hi := (t->>'hora_ini')::time; hf := (t->>'hora_fim')::time;
    itv := coalesce((t->>'intervalo')::int, 0); qtd := coalesce((t->>'qtd')::int, 1);
    if qtd < 1 or qtd > 200 then raise exception 'Quantidade de vagas inválida (1 a 200)'; end if;
    if itv <> 0 and (itv < 5 or hf <= hi) then raise exception 'Turno inválido: confira início, fim e intervalo'; end if;
  end loop;

  insert into unidade_procedimentos (unidade_id, procedimento_id)
  values (p_unidade, p_procedimento) on conflict do nothing;

  for d in select distinct x from unnest(p_datas) as x order by 1 loop
    if d < current_date - 1 or exists (
         select 1 from vagas where unidade_executante_id = p_unidade and procedimento_id = p_procedimento
                               and data = d and profissional_id is not distinct from p_profissional) then
      ignoradas := ignoradas || d; continue;
    end if;
    ndias := ndias + 1;
    for t in select * from jsonb_array_elements(p_turnos) loop
      hi := (t->>'hora_ini')::time; hf := (t->>'hora_fim')::time;
      itv := coalesce((t->>'intervalo')::int, 0); qtd := coalesce((t->>'qtd')::int, 1);
      if itv = 0 then
        for k in 1 .. qtd loop
          insert into vagas (unidade_executante_id, procedimento_id, profissional_id, profissional, data, hora)
          values (p_unidade, p_procedimento, p_profissional, v_prof, d, hi);
          n := n + 1;
        end loop;
      else
        for m in 0 .. (extract(epoch from (hf - hi)) / 60)::int - 1 by itv loop
          for k in 1 .. qtd loop
            insert into vagas (unidade_executante_id, procedimento_id, profissional_id, profissional, data, hora)
            values (p_unidade, p_procedimento, p_profissional, v_prof, d, hi + make_interval(mins => m));
            n := n + 1;
          end loop;
        end loop;
      end if;
    end loop;
  end loop;
  return jsonb_build_object('vagas', n, 'datas', ndias, 'ignoradas', to_jsonb(ignoradas));
end $$;

-- ---------------------------------------------------------------------
--  3. O MIRA PASSA A USAR O CBO DO PROFISSIONAL
-- ---------------------------------------------------------------------
drop function if exists mira_lote(date, date);
drop view if exists vw_mira;
create view vw_mira with (security_invoker = true) as
select
  s.protocolo                                   as identificador_registro,
  mira_status(s.status)                         as status_solicitacao,
  pr.codigo_sigtap                              as codigo_procedimento,
  s.created_at                                  as data_solicitacao,
  s.data_regulacao                              as data_autorizacao,
  s.data_execucao                               as data_execucao,
  coalesce(p.cns, p.cpf)                        as identificador_paciente,
  case when p.cns is not null then 'cns' else 'cpf' end as tipo_identificador_paciente,
  us.cnes                                       as cnes_solicitante,
  (select u2.cnes from unidades u2 where u2.reguladora order by u2.id limit 1) as cnes_regulador,
  ue.cnes                                       as cnes_executante,
  -- O CBO do profissional que executa é o que o modelo pede; o do
  -- procedimento fica como recurso para vaga sem profissional cadastrado.
  coalesce(prof.cbo, pr.cbo)                    as cbo_executante,
  pr.modalidade                                 as modalidade_assistencial,
  mira_caracter(s.prioridade)                   as caracter_solicitacao,
  s.cid10                                       as motivo_solicitacao,
  s.id                                          as solicitacao_id,
  s.updated_at                                  as atualizado_em
from solicitacoes s
join pacientes     p  on p.id  = s.paciente_id
join procedimentos pr on pr.id = s.procedimento_id
join unidades      us on us.id = s.unidade_solicitante_id
left join vagas    v  on v.id  = s.vaga_id
left join unidades ue on ue.id = v.unidade_executante_id
left join profissionais prof on prof.id = v.profissional_id;

revoke all on vw_mira from anon, authenticated;

create or replace function mira_lote(p_de date default null, p_ate date default null)
returns setof vw_mira
language plpgsql stable security definer set search_path = public as $$
begin
  if not tem_papel('admin','regulador') then
    raise exception 'Acesso à exportação MIRA restrito à regulação.' using errcode = '42501';
  end if;
  return query
    select * from vw_mira
     where codigo_procedimento is not null
       and identificador_paciente is not null
       and cnes_solicitante is not null
       and motivo_solicitacao is not null
       and (p_de  is null or atualizado_em::date >= p_de)
       and (p_ate is null or atualizado_em::date <= p_ate)
     order by atualizado_em;
end
$$;

do $$
declare fn regprocedure;
begin
 for fn in select p.oid::regprocedure from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public' and p.proname in ('gerar_vagas','mira_lote')
 loop
   execute format('revoke all on function %s from public, anon', fn);
   execute format('grant execute on function %s to authenticated', fn);
 end loop;
end $$;

-- MIGRACAO-004-FIM


-- ---------------------------------------------------------------------
-- 12. CATÁLOGO CID-10
--     Bloco idêntico ao de banco-de-dados/migracoes/005-catalogo-cid10.sql.
--     Os códigos em si vêm dos lotes de data/cid10/, gerados pelo workflow
--     "Preparar CID-10".
-- ---------------------------------------------------------------------
-- MIGRACAO-005-INICIO

-- ---------------------------------------------------------------------
--  1. CATÁLOGO
--
--  solicitacoes.cid10 era texto livre com maxlength 6. Isso aceita I20,
--  i20, "I 20" e I20.O com a letra O no lugar do zero — e o MIRA exige o
--  motivo da solicitação em CID-10 como campo obrigatório, então código
--  inválido vira registro recusado na transmissão.
--
--  Guardamos as categorias (3 caracteres, como I20) e as subcategorias
--  (4 caracteres, como I20.0), porque o médico escreve as duas formas.
--
--  O código é guardado com ponto, que é como se escreve na receita e no
--  pedido. codigo_limpo existe para a busca e para comparar com sistemas
--  que gravam sem pontuação.
-- ---------------------------------------------------------------------
create table if not exists cid10 (
  codigo       text primary key,
  codigo_limpo text generated always as (replace(codigo, '.', '')) stored,
  descricao    text not null,
  nivel        text not null check (nivel in ('categoria','subcategoria')),
  capitulo     text,
  competencia  text
);
create index if not exists cid10_limpo_idx on cid10 (codigo_limpo);
create index if not exists cid10_desc_idx  on cid10 (lower(descricao));

alter table cid10 enable row level security;
revoke all on cid10 from anon, authenticated;
grant select on cid10 to authenticated;
drop policy if exists cid_sel on cid10;
create policy cid_sel on cid10 for select to authenticated
  using (tem_papel('admin','regulador','agendador','solicitante','executante'));

-- ---------------------------------------------------------------------
--  2. VALIDAÇÃO
--
--  Enquanto o catálogo estiver vazio, aceita qualquer coisa com formato
--  de CID: é o que permite aplicar esta migração antes de importar os
--  lotes sem travar o registro de solicitação na recepção.
-- ---------------------------------------------------------------------
create or replace function cid10_valido(p text) returns boolean
language plpgsql stable set search_path = public as $$
declare v text;
begin
  v := upper(regexp_replace(coalesce(p, ''), '[^0-9A-Za-z]', '', 'g'));
  if v = '' then return true; end if;                 -- vazio é tratado por quem chama
  if v !~ '^[A-Z][0-9]{2}[0-9]?$' then return false; end if;
  if not exists (select 1 from cid10) then return true; end if;   -- catálogo ainda não importado
  return exists (select 1 from cid10 where codigo_limpo = v);
end $$;

/* Busca para a tela: por código ou por parte da descrição. Fica em função
   para o cliente não precisar baixar 14 mil linhas na memória — foi o erro
   que já existe com os procedimentos e que não vamos repetir aqui. */
create or replace function buscar_cid10(p_termo text, p_limite int default 20)
returns table (codigo text, descricao text, nivel text)
language sql stable security definer set search_path = public as $$
  with t as (select upper(trim(coalesce(p_termo, ''))) as termo)
  select c.codigo, c.descricao, c.nivel
    from cid10 c, t
   where length(t.termo) >= 2
     and (c.codigo_limpo like replace(t.termo, '.', '') || '%'
          or c.descricao ilike '%' || t.termo || '%')
   order by (c.codigo_limpo like replace(t.termo, '.', '') || '%') desc,
            length(c.codigo), c.codigo
   limit least(greatest(coalesce(p_limite, 20), 1), 50)
$$;

-- ---------------------------------------------------------------------
--  3. O MIRA PASSA A APONTAR CID FORA DO CATÁLOGO
-- ---------------------------------------------------------------------
create or replace function mira_pendencias()
returns table (problema text, solicitacoes bigint, como_resolver text)
language sql stable security definer set search_path = public as $$
  select * from (
    select 'Solicitação sem CID-10'::text, count(*),
           'O MIRA exige o motivo da solicitação em CID-10. Preencha na solicitação.'::text
      from solicitacoes where coalesce(trim(cid10), '') = ''
    union all
    select 'Solicitação com CID-10 fora do catálogo', count(*),
           'O código não existe na CID-10. Corrija na solicitação; o Ministério recusa código inválido.'
      from solicitacoes
     where coalesce(trim(cid10), '') <> '' and not cid10_valido(cid10)
    union all
    select 'Procedimento sem código SIGTAP', count(*),
           'O MIRA exige o código do procedimento. Preencha em Procedimentos.'
      from solicitacoes s join procedimentos pr on pr.id = s.procedimento_id
     where coalesce(trim(pr.codigo_sigtap), '') = ''
    union all
    select 'Unidade solicitante sem CNES', count(*),
           'O MIRA exige o CNES do estabelecimento solicitante. Preencha em Locais e unidades.'
      from solicitacoes s join unidades u on u.id = s.unidade_solicitante_id
     where coalesce(trim(u.cnes), '') = ''
    union all
    select 'Paciente sem CPF e sem Cartão SUS', count(*),
           'O MIRA identifica o paciente por CPF ou CNS. Complete o cadastro.'
      from solicitacoes s join pacientes p on p.id = s.paciente_id
     where coalesce(trim(p.cns), '') = '' and coalesce(trim(p.cpf), '') = ''
    union all
    select 'Nenhuma unidade marcada como reguladora', count(*),
           'Marque a unidade que opera a central em Locais e unidades: o CNES dela é o do estabelecimento regulador.'
      from solicitacoes
     where not exists (select 1 from unidades where reguladora)
  ) t(problema, solicitacoes, como_resolver)
  where t.solicitacoes > 0
  order by t.solicitacoes desc
$$;

do $$
declare fn regprocedure;
begin
 for fn in select p.oid::regprocedure from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public' and p.proname in ('cid10_valido','buscar_cid10','mira_pendencias')
 loop
   execute format('revoke all on function %s from public, anon', fn);
   execute format('grant execute on function %s to authenticated', fn);
 end loop;
end $$;

-- MIGRACAO-005-FIM


-- ---------------------------------------------------------------------
-- 13. ANEXOS DA SOLICITAÇÃO
--     Bloco idêntico ao de banco-de-dados/migracoes/006-anexos.sql.
--     Recria vw_solicitacoes com a contagem de anexos.
-- ---------------------------------------------------------------------
-- MIGRACAO-006-INICIO

-- ---------------------------------------------------------------------
--  1. REGISTRO DOS ANEXOS
--
--  Sem isto, o regulador decide sem ver o documento que fundamenta o
--  pedido: ele lê uma justificativa digitada pela atendente, que leu o
--  papel do médico. E o papel continua tendo que viajar até a central,
--  de modo que o sistema não substitui o processo em papel — vira mais
--  uma etapa em cima dele.
--
--  O arquivo em si vai para o Storage do Supabase, em bucket PRIVADO. Aqui
--  fica só o registro: quem enviou, quando, que documento é e onde está.
-- ---------------------------------------------------------------------
create table if not exists anexos (
  id             bigint generated always as identity primary key,
  solicitacao_id bigint not null references solicitacoes(id) on delete cascade,
  caminho        text   not null unique,
  nome_original  text   not null,
  tipo           text   not null,
  tamanho        int    not null check (tamanho > 0),
  documento      text   not null default 'pedido'
                 check (documento in ('pedido','exame','outro')),
  enviado_por    uuid references perfis(id) on delete set null,
  created_at     timestamptz not null default now()
);
create index if not exists anexos_sol_idx on anexos (solicitacao_id, created_at);

alter table anexos enable row level security;
revoke all on anexos from anon, authenticated;
grant select, insert, delete on anexos to authenticated;

/* Quem enxerga a solicitação enxerga os anexos dela. A subconsulta passa
   pelo RLS de solicitacoes, então a regra de visibilidade fica num lugar
   só e não precisa ser repetida aqui. */
drop policy if exists anx_sel on anexos;
create policy anx_sel on anexos for select to authenticated
  using (exists (select 1 from solicitacoes s where s.id = anexos.solicitacao_id));

drop policy if exists anx_ins on anexos;
create policy anx_ins on anexos for insert to authenticated
  with check (
    tem_papel('admin','regulador','agendador')
    or (tem_papel('solicitante') and exists (
          select 1 from solicitacoes s
           where s.id = anexos.solicitacao_id and s.unidade_solicitante_id = minha_unidade())));

/* Apagar anexo é destrutivo e o documento fundamenta a solicitação, então
   fica com a central. A unidade de origem corrige enviando outro. */
drop policy if exists anx_del on anexos;
create policy anx_del on anexos for delete to authenticated
  using (tem_papel('admin','regulador','agendador'));

-- ---------------------------------------------------------------------
--  2. BUCKET PRIVADO E ACESSO AO ARQUIVO
--
--  O caminho é "<solicitacao_id>/<arquivo>", e é dele que sai a regra de
--  acesso: quem enxerga a solicitação enxerga o arquivo. Bucket privado,
--  então a leitura só acontece por URL assinada, com validade curta.
-- ---------------------------------------------------------------------
do $$
begin
  if to_regclass('storage.buckets') is null then
    raise notice 'Schema storage ausente: pulei bucket e políticas de arquivo.';
    return;
  end if;

  insert into storage.buckets (id, name, public)
  values ('anexos', 'anexos', false)
  on conflict (id) do update set public = false;
end $$;

create or replace function sol_do_caminho(p_caminho text) returns bigint
language sql immutable as $$
  select nullif(regexp_replace(split_part(coalesce(p_caminho, ''), '/', 1), '\D', '', 'g'), '')::bigint
$$;

create or replace function pode_ver_anexo(p_caminho text) returns boolean
language sql stable set search_path = public as $$
  -- O RLS de solicitacoes decide. Função existe para a política do Storage
  -- não precisar repetir a regra de visibilidade.
  select exists (select 1 from solicitacoes s where s.id = sol_do_caminho(p_caminho))
$$;

create or replace function pode_anexar(p_caminho text) returns boolean
language sql stable set search_path = public as $$
  select tem_papel('admin','regulador','agendador')
      or (tem_papel('solicitante') and exists (
            select 1 from solicitacoes s
             where s.id = sol_do_caminho(p_caminho)
               and s.unidade_solicitante_id = minha_unidade()))
$$;

do $$
begin
  if to_regclass('storage.objects') is null then return; end if;

  execute 'drop policy if exists anexo_ler on storage.objects';
  execute $p$create policy anexo_ler on storage.objects for select to authenticated
             using (bucket_id = 'anexos' and pode_ver_anexo(name))$p$;

  execute 'drop policy if exists anexo_enviar on storage.objects';
  execute $p$create policy anexo_enviar on storage.objects for insert to authenticated
             with check (bucket_id = 'anexos' and pode_anexar(name))$p$;

  execute 'drop policy if exists anexo_apagar on storage.objects';
  execute $p$create policy anexo_apagar on storage.objects for delete to authenticated
             using (bucket_id = 'anexos' and tem_papel('admin','regulador','agendador'))$p$;
end $$;

-- ---------------------------------------------------------------------
--  3. QUANTOS ANEXOS CADA SOLICITAÇÃO TEM
--  A contagem entra na view para as listas marcarem quem está sem pedido
--  anexado, sem uma consulta por linha.
-- ---------------------------------------------------------------------
drop function if exists mira_lote(date, date);
-- Sem cascade de propósito: nada depende desta view hoje, e se um dia
-- algo depender é melhor a migração falhar e avisar do que apagar em
-- silêncio um objeto que alguém criou no banco do município.
drop view if exists vw_solicitacoes;
create view vw_solicitacoes with (security_invoker = true) as
select
  s.*,
  p.nome            as paciente_nome,
  p.nome_social     as paciente_nome_social,
  p.cns             as paciente_cns,
  p.cpf             as paciente_cpf,
  p.data_nascimento as paciente_nascimento,
  p.sexo            as paciente_sexo,
  p.telefone        as paciente_telefone,
  p.telefone2       as paciente_telefone2,
  p.nome_mae        as paciente_mae,
  concat_ws(', ', nullif(p.logradouro,''), nullif(p.numero,''), nullif(p.complemento,''),
            nullif(p.bairro,''), nullif(concat_ws('/', nullif(p.cidade,''), nullif(p.uf,'')),'')) as paciente_endereco,
  pr.nome           as procedimento_nome,
  pr.exige_regulacao,
  pr.codigo_sigtap  as procedimento_codigo,
  pr.tipo           as procedimento_tipo,
  pr.especialidade,
  u.nome            as unidade_solicitante_nome,
  uo.nome           as unidade_origem_nome,
  v.data            as vaga_data,
  v.hora            as vaga_hora,
  v.profissional    as vaga_profissional,
  v.unidade_executante_id,
  ue.nome           as unidade_executante_nome,
  ue.endereco       as unidade_executante_endereco,
  ue.telefone       as unidade_executante_telefone,
  rg.nome           as regulador_nome,
  cf.nome           as confirmado_por_nome,
  (current_date - s.created_at::date)   as dias_espera,
  (current_date - s.data_pedido)        as dias_desde_pedido,
  (s.created_at::date - s.data_pedido)  as dias_ate_insercao,
  coalesce(vu.peso, 0)                  as peso_vulnerabilidade,
  coalesce(vu.nomes, array[]::text[])   as vulnerabilidades,
  coalesce(ax.total, 0)                 as anexos,
  coalesce(ax.pedidos, 0)               as anexos_pedido,
  case s.prioridade when 'vermelho' then 1 when 'amarelo' then 2
                    when 'verde' then 3 else 4 end as peso_prioridade
from solicitacoes s
join pacientes     p  on p.id  = s.paciente_id
join procedimentos pr on pr.id = s.procedimento_id
join unidades      u  on u.id  = s.unidade_solicitante_id
left join unidades uo on uo.id = s.unidade_origem_id
left join vagas    v  on v.id  = s.vaga_id
left join unidades ue on ue.id = v.unidade_executante_id
left join perfis   rg on rg.id = s.regulador_id
left join perfis   cf on cf.id = s.confirmado_por
left join lateral (
  select sum(c.peso) as peso, array_agg(c.nome order by c.nome) as nomes
    from solicitacao_vulnerabilidade sv
    join criterios_vulnerabilidade c on c.id = sv.criterio_id and c.ativo
   where sv.solicitacao_id = s.id
) vu on true
left join lateral (
  select count(*) as total, count(*) filter (where a.documento = 'pedido') as pedidos
    from anexos a where a.solicitacao_id = s.id
) ax on true;

grant select on vw_solicitacoes to authenticated;

create or replace function mira_lote(p_de date default null, p_ate date default null)
returns setof vw_mira
language plpgsql stable security definer set search_path = public as $$
begin
  if not tem_papel('admin','regulador') then
    raise exception 'Acesso à exportação MIRA restrito à regulação.' using errcode = '42501';
  end if;
  return query
    select * from vw_mira
     where codigo_procedimento is not null
       and identificador_paciente is not null
       and cnes_solicitante is not null
       and motivo_solicitacao is not null
       and (p_de  is null or atualizado_em::date >= p_de)
       and (p_ate is null or atualizado_em::date <= p_ate)
     order by atualizado_em;
end
$$;

do $$
declare fn regprocedure;
begin
 for fn in select p.oid::regprocedure from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public' and p.proname in ('pode_ver_anexo','pode_anexar','sol_do_caminho','mira_lote')
 loop
   execute format('revoke all on function %s from public, anon', fn);
   execute format('grant execute on function %s to authenticated', fn);
 end loop;
end $$;

-- MIGRACAO-006-FIM

-- MIGRACAO-007-INICIO

-- ---------------------------------------------------------------------
--  A CENTRAL DE REGULAÇÃO É UM TIPO DE UNIDADE
--
--  "tipo" diz o que a unidade faz no fluxo, e é o que filtra as duas
--  listas do sistema: de onde o pedido sai, e onde o paciente é
--  atendido. A central não é nenhuma das duas — ela recebe o pedido da
--  unidade de origem e decide. Cadastrá-la como solicitante a fazia
--  aparecer na lista de origem do pedido, oferecendo à atendente uma
--  opção que nunca é a resposta certa.
--
--  Daí o quarto valor. E, junto, os filtros do aplicativo passaram a ser
--  listas do que entra, não do que fica de fora: escritos como negação,
--  qualquer tipo novo entraria por engano na lista de origem.
--
--  A coluna reguladora (migração 003) continua existindo porque é dela
--  que a vw_mira lê o CNES do estabelecimento regulador. Mas deixa de
--  ser preenchida à mão: passa a ser derivada do tipo, de modo que não
--  existe o estado em que a tela diz uma coisa e o lote enviado ao
--  Ministério diz outra.
-- ---------------------------------------------------------------------
-- A coluna vem da migração 003. Repetida aqui, sem efeito se já existe, para
-- que esta migração possa ser colada sozinha no SQL Editor sem falhar.
alter table unidades
  add column if not exists reguladora boolean not null default false;

alter table unidades drop constraint if exists unidades_tipo_check;
alter table unidades add constraint unidades_tipo_check
  check (tipo in ('solicitante','executante','ambos','regulacao'));

comment on column unidades.tipo is
  'Papel da unidade no fluxo: solicitante (origem do pedido), executante (local de atendimento), ambos, ou regulacao (a central, que não é origem nem local de atendimento).';

-- Bancos que aplicaram a 003 e marcaram a reguladora à mão: preserva a
-- intenção, convertendo a marca em tipo antes de a marca virar derivada.
update unidades set tipo = 'regulacao'
 where reguladora and tipo <> 'regulacao'
   and id = (select min(id) from unidades where reguladora);

-- Só uma central. A segunda é recusada, em vez de a primeira cair em
-- silêncio: trocar a central é uma decisão, não um efeito colateral.
create unique index if not exists unidades_uma_reguladora
  on unidades ((tipo)) where tipo = 'regulacao';

create or replace function sincronizar_reguladora()
returns trigger language plpgsql as $$
begin
  new.reguladora := (new.tipo = 'regulacao');
  return new;
end $$;

comment on function sincronizar_reguladora() is
  'Mantém unidades.reguladora derivada de unidades.tipo, para que a marca lida pelo MIRA não possa divergir do que a tela mostra.';

drop trigger if exists unica_reguladora on unidades;          -- versão anterior desta migração
drop function if exists marcar_unica_reguladora();
drop trigger if exists reguladora_do_tipo on unidades;
create trigger reguladora_do_tipo
  before insert or update on unidades
  for each row execute function sincronizar_reguladora();

update unidades set reguladora = (tipo = 'regulacao')
 where reguladora is distinct from (tipo = 'regulacao');

-- MIGRACAO-007-FIM

-- MIGRACAO-008-INICIO

-- ---------------------------------------------------------------------
--  1. EXAME DE LABORATÓRIO
--
--  O modelo do sistema é uma vaga por procedimento e por horário: o
--  paciente é marcado para uma consulta de cardiologia às 14h. Para o
--  laboratório isso não descreve o que acontece. O paciente chega com um
--  pedido de oito exames, faz a coleta uma vez, e o que limita o dia é
--  quantas pessoas o laboratório coleta, não quantos exames.
--
--  Abrir uma agenda por exame produziria oito marcações para a mesma
--  coleta, oito guias, e um controle de vagas que não corresponde a
--  nada no mundo.
--
--  Quais exames seguem esse modelo é decisão do município, exame por
--  exame — e não do tipo "exame" da SIGTAP, que também cobre raio-x e
--  ultrassom, que têm hora marcada de verdade.
-- ---------------------------------------------------------------------
alter table procedimentos
  add column if not exists laboratorio boolean not null default false;
comment on column procedimentos.laboratorio is
  'Quando true, é agendado na agenda diária do laboratório, junto com os outros exames do mesmo pedido, numa guia só.';

-- ---------------------------------------------------------------------
--  2. VAGA DE DIA
--
--  Uma linha em vagas passa a poder representar o dia inteiro de um
--  local: sem procedimento (serve qualquer exame de laboratório que o
--  local realiza), sem hora, e com capacidade — quantos PACIENTES cabem.
--
--  As vagas antigas não mudam: capacidade 1, procedimento e hora
--  preenchidos, um paciente cada.
-- ---------------------------------------------------------------------
alter table vagas alter column procedimento_id drop not null;
alter table vagas alter column hora            drop not null;
alter table vagas add column if not exists capacidade int not null default 1;

alter table vagas drop constraint if exists vagas_capacidade_ck;
alter table vagas add constraint vagas_capacidade_ck check (capacidade between 1 and 500);

-- Vaga de dia não tem hora; vaga de horário tem. Sem isto, uma vaga de
-- procedimento sem hora passaria batido e quebraria a guia impressa.
alter table vagas drop constraint if exists vagas_dia_ck;
alter table vagas add constraint vagas_dia_ck check (
  (procedimento_id is not null and hora is not null)
  or (procedimento_id is null and hora is null)
);

comment on column vagas.capacidade is 'Quantos pacientes cabem nesta vaga. 1 nas vagas de horário; o teto do dia nas vagas de laboratório.';

-- Quantos pacientes já ocupam a vaga. Conta paciente, não solicitação:
-- os oito exames de uma coleta são uma pessoa só na fila do dia.
create or replace function vaga_ocupacao(p_vaga bigint)
returns int language sql stable as $$
  select count(distinct paciente_id)::int
    from solicitacoes
   where vaga_id = p_vaga and status <> 'cancelada'
$$;

-- ---------------------------------------------------------------------
--  3. ABRIR A AGENDA DO LABORATÓRIO
--
--  Função separada de gerar_vagas de propósito: a de horário tem turnos,
--  intervalo e profissional, e misturar os dois casos numa função só
--  deixaria as duas difíceis de ler e de mudar.
-- ---------------------------------------------------------------------
create or replace function gerar_vagas_dia(
  p_unidade bigint, p_datas date[], p_capacidade int
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare d date; n int := 0; ignoradas date[] := '{}';
begin
  if not tem_papel('admin','agendador','regulador') then raise exception 'Sem permissão para gerar vagas'; end if;
  if not exists (select 1 from unidades where id = p_unidade and ativo and tipo in ('executante','ambos')) then
    raise exception 'Escolha um local de atendimento ativo';
  end if;
  if p_datas is null or cardinality(p_datas) = 0 then raise exception 'Nenhuma data informada'; end if;
  if cardinality(p_datas) > 400 then raise exception 'Máximo de 400 datas por vez'; end if;
  if p_capacidade is null or p_capacidade < 1 or p_capacidade > 500 then
    raise exception 'Capacidade inválida (1 a 500 pacientes por dia)';
  end if;
  if not exists (select 1 from unidade_procedimentos up
                   join procedimentos pr on pr.id = up.procedimento_id
                  where up.unidade_id = p_unidade and pr.laboratorio and pr.ativo) then
    raise exception 'Este local não tem nenhum exame de laboratório marcado como realizado aqui';
  end if;

  for d in select distinct x from unnest(p_datas) as x order by 1 loop
    -- data passada, ou dia que já tem agenda: não duplica, avisa
    if d < current_date - 1
       or exists (select 1 from vagas where unidade_executante_id = p_unidade
                                        and procedimento_id is null and data = d) then
      ignoradas := ignoradas || d; continue;
    end if;
    insert into vagas (unidade_executante_id, procedimento_id, profissional_id, profissional, data, hora, capacidade)
    values (p_unidade, null, null, null, d, null, p_capacidade);
    n := n + 1;
  end loop;
  return jsonb_build_object('vagas', n, 'datas', n, 'ignoradas', to_jsonb(ignoradas));
end $$;

-- Dias abertos do laboratório, com quanto já foi usado. É o que a tela de
-- agendamento lê para mostrar "12 de 30 ocupados".
create or replace function dias_laboratorio(p_unidade bigint, p_de date default null, p_ate date default null)
returns table (vaga_id bigint, data date, capacidade int, ocupadas int, livres int)
language sql stable security definer set search_path = public as $$
  select v.id, v.data, v.capacidade,
         vaga_ocupacao(v.id),
         greatest(v.capacidade - vaga_ocupacao(v.id), 0)
    from vagas v
   where v.procedimento_id is null
     and v.unidade_executante_id = p_unidade
     and v.status <> 'bloqueada'
     and v.data >= coalesce(p_de, current_date)
     and (p_ate is null or v.data <= p_ate)
   order by v.data
$$;

-- ---------------------------------------------------------------------
--  4. A VAGA DE DIA NÃO ENTRA NO AGENDAMENTO COMUM
-- ---------------------------------------------------------------------
create or replace function agendar(p_solicitacao bigint, p_vaga bigint, p_obs text default null)
returns text
language plpgsql security definer set search_path = public as $$
declare s solicitacoes; v vagas; v_guia text; remarcar boolean; apos_falta boolean;
begin
  select * into s from solicitacoes where id = p_solicitacao for update;
  if not found then raise exception 'Solicitação não encontrada'; end if;
  if not (tem_papel('admin','regulador','agendador')
          or (tem_papel('solicitante') and coalesce(s.unidade_solicitante_id = minha_unidade(),false))) then
    raise exception 'Sem permissão para agendar';
  end if;
  if s.status not in ('pendente','autorizada','agendada','faltou') then
    raise exception 'Esta solicitação não pode ser agendada (status: %)', s.status;
  end if;
  if s.status = 'pendente' and exists (select 1 from procedimentos where id = s.procedimento_id and exige_regulacao) then
    raise exception 'Este procedimento exige regulação: a solicitação precisa ser autorizada pelo regulador antes do agendamento';
  end if;
  apos_falta := s.status = 'faltou';
  if apos_falta and coalesce(trim(p_obs), '') = '' then
    raise exception 'Informe o motivo do reagendamento após a falta';
  end if;
  remarcar := s.status = 'agendada';

  select * into v from vagas where id = p_vaga for update;
  if not found or v.status <> 'livre' then raise exception 'Vaga indisponível — escolha outro horário'; end if;
  -- Vaga de dia (sem procedimento) não entra por aqui: ela cabe vários
  -- exames do mesmo paciente numa guia só, e o caminho dela é o
  -- agendar_laboratorio. Sem esta linha a comparação com NULL daria
  -- "desconhecido", a condição não seria verdadeira, e a vaga do dia
  -- seria tomada por um paciente só.
  if v.procedimento_id is null then
    raise exception 'Esta é a agenda diária do laboratório: agende por ela, escolhendo os exames do pedido';
  end if;
  if v.procedimento_id <> s.procedimento_id then raise exception 'A vaga é de outro procedimento'; end if;
  if v.data < current_date - 1 then raise exception 'A vaga está em data passada'; end if;

  if remarcar and s.vaga_id is not null then
    update vagas set status = 'livre' where id = s.vaga_id;
  end if;
  update vagas set status = 'ocupada' where id = p_vaga;

  v_guia := coalesce(s.numero_guia, gerar_guia());
  perform set_config('regula.obs',
    case when apos_falta then 'Reagendado após falta' when remarcar then 'Remarcado' else 'Agendado' end || ' para ' ||
    to_char(v.data, 'DD/MM/YYYY') || ' às ' || to_char(v.hora, 'HH24:MI') ||
    ' — ' || (select nome from unidades where id = v.unidade_executante_id) || ' — Guia ' || v_guia ||
    coalesce(' — ' || nullif(trim(p_obs), ''), ''), true);

  update solicitacoes set
    status = 'agendada', vaga_id = p_vaga, numero_guia = v_guia, data_agendamento = now(),
    -- limpa o desfecho anterior, senão a falta antiga fica grudada na solicitação
    data_execucao  = case when apos_falta then null else data_execucao end,
    confirmado_por = case when apos_falta then null else confirmado_por end,
    obs_execucao   = case when apos_falta then null else obs_execucao end
  where id = p_solicitacao;
  return v_guia;
end $$;

-- ---------------------------------------------------------------------
--  5. UMA GUIA PARA VÁRIOS EXAMES
--
--  numero_guia deixa de ser único: ele passa a identificar a guia, não a
--  solicitação. Os oito exames de uma coleta carregam o mesmo número, e é
--  por ele que o laboratório confirma o atendimento de uma vez.
--
--  O número continua vindo de gerar_guia(), que usa uma sequência, então
--  dois grupos nunca recebem o mesmo. O que se perde com o unique é a
--  proteção contra alguém escrever o número à mão — e ninguém escreve: a
--  coluna só é preenchida por agendar() e agendar_laboratorio().
-- ---------------------------------------------------------------------
alter table solicitacoes drop constraint if exists solicitacoes_numero_guia_key;
create index if not exists solicitacoes_numero_guia_idx on solicitacoes (numero_guia);

-- ---------------------------------------------------------------------
--  6. AGENDAR O PEDIDO INTEIRO
--
--  Recebe as solicitações escolhidas, todas do mesmo paciente, e põe
--  todas no mesmo dia, com o mesmo número de guia.
-- ---------------------------------------------------------------------
create or replace function agendar_laboratorio(p_solicitacoes bigint[], p_vaga bigint, p_obs text default null)
returns text
language plpgsql security definer set search_path = public as $$
declare
  v vagas; s solicitacoes; i bigint; pac bigint; v_guia text;
  ja int; nomes text; antiga bigint; apos_falta boolean := false;
begin
  if not tem_papel('admin','regulador','agendador') then raise exception 'Sem permissão para agendar'; end if;
  if p_solicitacoes is null or cardinality(p_solicitacoes) = 0 then raise exception 'Nenhum exame selecionado'; end if;
  if cardinality(p_solicitacoes) > 60 then raise exception 'Máximo de 60 exames por guia'; end if;

  select * into v from vagas where id = p_vaga for update;
  if not found then raise exception 'Agenda não encontrada'; end if;
  if v.procedimento_id is not null then
    raise exception 'Esta vaga é de um procedimento com horário: use o agendamento comum';
  end if;
  if v.status = 'bloqueada' then raise exception 'Esta agenda está bloqueada'; end if;
  if v.data < current_date - 1 then raise exception 'A agenda está em data passada'; end if;

  -- 1ª passada: conferir tudo antes de mudar qualquer coisa, para não
  -- deixar metade do pedido agendado e metade não.
  foreach i in array p_solicitacoes loop
    select * into s from solicitacoes where solicitacoes.id = i for update;
    if not found then raise exception 'Solicitação % não encontrada', i; end if;
    if pac is null then pac := s.paciente_id;
    elsif pac <> s.paciente_id then raise exception 'Os exames selecionados são de pacientes diferentes'; end if;

    if s.status not in ('pendente','autorizada','agendada','faltou') then
      raise exception 'O exame % não pode ser agendado (situação: %)', s.protocolo, s.status;
    end if;
    if s.status = 'faltou' then apos_falta := true; end if;
    if s.status = 'pendente' and exists (select 1 from procedimentos where id = s.procedimento_id and exige_regulacao) then
      raise exception 'O exame % exige regulação: precisa ser autorizado antes do agendamento', s.protocolo;
    end if;
    if not exists (select 1 from procedimentos where id = s.procedimento_id and laboratorio) then
      select nome into nomes from procedimentos where id = s.procedimento_id;
      raise exception '% não está marcado como exame de laboratório', nomes;
    end if;
    if not exists (select 1 from unidade_procedimentos
                    where unidade_id = v.unidade_executante_id and procedimento_id = s.procedimento_id) then
      select nome into nomes from procedimentos where id = s.procedimento_id;
      raise exception 'Este local não realiza %', nomes;
    end if;
  end loop;

  if apos_falta and coalesce(trim(p_obs), '') = '' then
    raise exception 'Informe o motivo do reagendamento após a falta';
  end if;

  -- Capacidade: conta pacientes. Quem já está no dia não ocupa de novo.
  if not exists (select 1 from solicitacoes
                  where vaga_id = p_vaga and paciente_id = pac and status <> 'cancelada') then
    ja := vaga_ocupacao(p_vaga);
    if ja >= v.capacidade then
      raise exception 'A agenda de % já está cheia (% de % pacientes)',
        to_char(v.data, 'DD/MM/YYYY'), ja, v.capacidade;
    end if;
  end if;

  -- A guia é do paciente naquele dia: se ele já tem exames marcados nesta
  -- agenda, os novos entram na mesma guia em vez de criar uma segunda.
  select numero_guia into v_guia from solicitacoes
   where vaga_id = p_vaga and paciente_id = pac and numero_guia is not null
     and status <> 'cancelada' limit 1;
  v_guia := coalesce(v_guia, gerar_guia());

  perform set_config('regula.obs',
    'Agendado para ' || to_char(v.data, 'DD/MM/YYYY') ||
    ' — ' || (select nome from unidades where id = v.unidade_executante_id) ||
    ' — Guia ' || v_guia || coalesce(' — ' || nullif(trim(p_obs), ''), ''), true);

  -- 2ª passada: agora muda.
  foreach i in array p_solicitacoes loop
    select vaga_id into antiga from solicitacoes where solicitacoes.id = i;
    if antiga is not null and antiga <> p_vaga then
      -- devolve a vaga de horário que ficou para trás; a de dia se recompõe sozinha
      update vagas set status = 'livre' where id = antiga and procedimento_id is not null;
    end if;
    update solicitacoes set
      status = 'agendada', vaga_id = p_vaga, numero_guia = v_guia, data_agendamento = now(),
      data_execucao = null, confirmado_por = null, obs_execucao = null
    where solicitacoes.id = i;
  end loop;

  update vagas set status = case when vaga_ocupacao(p_vaga) >= capacidade then 'ocupada' else 'livre' end
   where id = p_vaga;
  return v_guia;
end $$;

-- ---------------------------------------------------------------------
--  7. CONFIRMAR A GUIA INTEIRA
--
--  Antes, uma guia era uma solicitação, e select into pegava a única
--  linha. Com várias, ele pegaria uma e ignoraria as outras em silêncio:
--  o laboratório confirmaria a coleta e sete exames continuariam
--  "agendados" para sempre. Agora a confirmação vale para todas as
--  linhas da guia que ainda estão agendadas.
-- ---------------------------------------------------------------------
create or replace function confirmar_atendimento(p_guia text, p_status text, p_obs text default null)
returns void
language plpgsql security definer set search_path = public as $$
declare v vagas; v_vaga bigint; n int; abertas int;
begin
  if p_status not in ('realizada','faltou') then raise exception 'Status inválido'; end if;

  perform 1 from solicitacoes where numero_guia = trim(p_guia) for update;
  select count(*), count(*) filter (where status = 'agendada'), min(vaga_id)
    into n, abertas, v_vaga
    from solicitacoes where numero_guia = trim(p_guia);
  if n = 0 then raise exception 'Guia % não encontrada', p_guia; end if;
  if abertas = 0 then raise exception 'Esta guia já foi finalizada'; end if;

  select * into v from vagas where id = v_vaga;
  if not (tem_papel('admin','regulador','agendador')
          or (tem_papel('executante') and coalesce(v.unidade_executante_id = minha_unidade(),false))) then
    raise exception 'Esta guia pertence a outro local de atendimento';
  end if;
  if p_status = 'realizada' and v.data > current_date + 1 then
    raise exception 'Não é possível confirmar a execução antes da data agendada (%)', to_char(v.data, 'DD/MM/YYYY');
  end if;

  perform set_config('regula.obs',
    case p_status when 'realizada' then 'Execução confirmada' else 'Falta registrada' end
    || coalesce(' — ' || nullif(trim(p_obs), ''), ''), true);
  update solicitacoes set
    status = p_status::status_solicitacao, data_execucao = now(),
    confirmado_por = auth.uid(), obs_execucao = nullif(trim(p_obs), '')
  where numero_guia = trim(p_guia) and status = 'agendada';
end $$;

do $$
declare fn regprocedure;
begin
 for fn in select p.oid::regprocedure from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public' and p.proname in ('gerar_vagas_dia','agendar_laboratorio','dias_laboratorio','vaga_ocupacao')
 loop
   execute format('revoke all on function %s from public, anon', fn);
   execute format('grant execute on function %s to authenticated', fn);
 end loop;
end $$;

-- ---------------------------------------------------------------------
--  8. A VIEW PASSA A DIZER O QUE É LABORATÓRIO
--
--  Sem isso a tela de agendamento teria que consultar procedimentos
--  linha a linha para saber qual caminho oferecer.
-- ---------------------------------------------------------------------
drop view if exists vw_solicitacoes;
create view vw_solicitacoes with (security_invoker = true) as
select
  s.*,
  p.nome            as paciente_nome,
  p.nome_social     as paciente_nome_social,
  p.cns             as paciente_cns,
  p.cpf             as paciente_cpf,
  p.data_nascimento as paciente_nascimento,
  p.sexo            as paciente_sexo,
  p.telefone        as paciente_telefone,
  p.telefone2       as paciente_telefone2,
  p.nome_mae        as paciente_mae,
  concat_ws(', ', nullif(p.logradouro,''), nullif(p.numero,''), nullif(p.complemento,''),
            nullif(p.bairro,''), nullif(concat_ws('/', nullif(p.cidade,''), nullif(p.uf,'')),'')) as paciente_endereco,
  pr.nome           as procedimento_nome,
  pr.exige_regulacao,
  pr.codigo_sigtap  as procedimento_codigo,
  pr.tipo           as procedimento_tipo,
  pr.laboratorio    as procedimento_laboratorio,
  pr.especialidade,
  u.nome            as unidade_solicitante_nome,
  uo.nome           as unidade_origem_nome,
  v.data            as vaga_data,
  v.hora            as vaga_hora,
  v.profissional    as vaga_profissional,
  v.capacidade      as vaga_capacidade,
  v.unidade_executante_id,
  ue.nome           as unidade_executante_nome,
  ue.endereco       as unidade_executante_endereco,
  ue.telefone       as unidade_executante_telefone,
  rg.nome           as regulador_nome,
  cf.nome           as confirmado_por_nome,
  (current_date - s.created_at::date)   as dias_espera,
  (current_date - s.data_pedido)        as dias_desde_pedido,
  (s.created_at::date - s.data_pedido)  as dias_ate_insercao,
  coalesce(vu.peso, 0)                  as peso_vulnerabilidade,
  coalesce(vu.nomes, array[]::text[])   as vulnerabilidades,
  coalesce(ax.total, 0)                 as anexos,
  coalesce(ax.pedidos, 0)               as anexos_pedido,
  case s.prioridade when 'vermelho' then 1 when 'amarelo' then 2
                    when 'verde' then 3 else 4 end as peso_prioridade
from solicitacoes s
join pacientes     p  on p.id  = s.paciente_id
join procedimentos pr on pr.id = s.procedimento_id
join unidades      u  on u.id  = s.unidade_solicitante_id
left join unidades uo on uo.id = s.unidade_origem_id
left join vagas    v  on v.id  = s.vaga_id
left join unidades ue on ue.id = v.unidade_executante_id
left join perfis   rg on rg.id = s.regulador_id
left join perfis   cf on cf.id = s.confirmado_por
left join lateral (
  select sum(c.peso) as peso, array_agg(c.nome order by c.nome) as nomes
    from solicitacao_vulnerabilidade sv
    join criterios_vulnerabilidade c on c.id = sv.criterio_id and c.ativo
   where sv.solicitacao_id = s.id
) vu on true
left join lateral (
  select count(*) as total, count(*) filter (where a.documento = 'pedido') as pedidos
    from anexos a where a.solicitacao_id = s.id
) ax on true;

grant select on vw_solicitacoes to authenticated;

-- MIGRACAO-008-FIM

-- MIGRACAO-009-INICIO

-- ---------------------------------------------------------------------
--  1. UM PROTOCOLO PARA O PEDIDO, NÃO PARA CADA EXAME
--
--  O médico pede oito exames de laboratório numa folha só. O paciente
--  entende isso como um pedido: ele sai da unidade com um número, faz a
--  coleta num dia, e pergunta por aquele número. Oito protocolos para a
--  mesma folha obrigam a decorar oito números e a consultar oito vezes
--  para saber se a coleta foi marcada.
--
--  Então protocolo passa a identificar o PEDIDO. As solicitações continuam
--  separadas por dentro — cada exame tem seu procedimento, seu faturamento
--  e seu desfecho — mas compartilham o número que vai para o papel.
--
--  Vale para os exames de laboratório registrados juntos. Consulta e exame
--  de imagem seguem com protocolo próprio: eles são atendimentos
--  diferentes, em dias e locais diferentes, e juntar os números só
--  confundiria quem acompanha.
-- ---------------------------------------------------------------------
alter table solicitacoes drop constraint if exists solicitacoes_protocolo_key;
create index if not exists solicitacoes_protocolo_idx on solicitacoes (protocolo);

comment on column solicitacoes.protocolo is
  'Número do pedido, informado ao paciente. Os exames de laboratório de um mesmo pedido compartilham o número; os demais procedimentos têm o seu.';

-- ---------------------------------------------------------------------
--  2. O ACOMPANHAMENTO PASSA A DEVOLVER O PEDIDO INTEIRO
--
--  Era "select into": com várias linhas ele pegava uma e descartava o
--  resto sem avisar, e o paciente veria um exame dos oito.
--
--  A trava de volume continua contando uma consulta por protocolo, não uma
--  por exame: quem consulta um pedido de oito não gasta oito tentativas.
-- ---------------------------------------------------------------------
drop function if exists consultar_protocolo(text, date);
create function consultar_protocolo(p_protocolo text, p_nascimento date)
returns table (
  resultado            text,   -- 'ok' | 'nao_encontrado' | 'limite' | 'incompleto'
  protocolo            text,
  situacao             text,
  exige_regulacao      boolean,
  procedimento         text,
  data_pedido          date,
  dias_desde_pedido    int,
  posicao              int,
  agendada_data        date,
  agendada_hora        time,
  local_nome           text,
  local_endereco       text,
  local_telefone       text,
  parecer              text
)
language plpgsql security definer set search_path = public as $$
declare
  v_prot  text := upper(regexp_replace(coalesce(p_protocolo, ''), '[^0-9A-Za-z]', '', 'g'));
  s       record;
  n_prot  int;
  n_geral int;
  v_pos   int;
  achou   boolean := false;
begin
  -- Esta função devolve o erro como dado, em "resultado", e não com
  -- raise exception. O motivo é a trava de volume logo abaixo: raise
  -- desfaz a transação inteira, inclusive o insert que registra a
  -- tentativa, então o contador nunca subiria e a trava não existiria
  -- na prática. Testado: com raise, 12 tentativas passavam das 10.
  if v_prot = '' or p_nascimento is null then
    return query select 'incompleto'::text, null::text, null::text, null::boolean, null::text,
                        null::date, null::int, null::int, null::date, null::time,
                        null::text, null::text, null::text, null::text;
    return;
  end if;

  -- As colunas de retorno desta função (protocolo, situacao, ...) também são
  -- variáveis dentro do corpo, então toda coluna de tabela com nome igual
  -- precisa vir qualificada, ou o Postgres recusa por ambiguidade.
  select count(*) into n_prot  from consultas_publicas cp
   where cp.protocolo = v_prot and cp.created_at > now() - interval '1 hour';
  select count(*) into n_geral from consultas_publicas cp
   where cp.created_at > now() - interval '1 minute';

  if n_prot >= 10 or n_geral >= 60 then
    insert into consultas_publicas (protocolo, sucesso) values (v_prot, false);
    return query select 'limite'::text, null::text, null::text, null::boolean, null::text,
                        null::date, null::int, null::int, null::date, null::time,
                        null::text, null::text, null::text, null::text;
    return;
  end if;

  for s in
    select sol.id, sol.protocolo, sol.status, sol.prioridade, sol.created_at, sol.data_pedido,
           sol.procedimento_id, sol.parecer, sol.vaga_id,
           pr.nome as proc_nome, pr.exige_regulacao,
           vg.data as vdata, vg.hora as vhora,
           ue.nome as uenome, ue.endereco as ueend, ue.telefone as uetel
      from solicitacoes sol
      join pacientes     pa on pa.id = sol.paciente_id
      join procedimentos pr on pr.id = sol.procedimento_id
      left join vagas    vg on vg.id = sol.vaga_id
      left join unidades ue on ue.id = vg.unidade_executante_id
     where sol.protocolo = v_prot
       and pa.data_nascimento = p_nascimento
     order by pr.nome
  loop
    achou := true;
    v_pos := null;
    if s.status in ('pendente','autorizada') then
      select count(*) + 1 into v_pos
        from solicitacoes o
       where o.procedimento_id = s.procedimento_id
         and o.status in ('pendente','autorizada')
         and (case o.prioridade when 'vermelho' then 1 when 'amarelo' then 2
                                when 'verde' then 3 else 4 end, o.created_at)
           < (case s.prioridade when 'vermelho' then 1 when 'amarelo' then 2
                                when 'verde' then 3 else 4 end, s.created_at);
    end if;

    return query select
      'ok'::text,
      s.protocolo,
      case s.status
        when 'pendente'   then case when s.exige_regulacao then 'Em análise pela regulação'
                                    else 'Aguardando marcação' end
        when 'autorizada' then 'Autorizada — aguardando vaga'
        when 'devolvida'  then 'Devolvida à unidade de origem para correção'
        when 'negada'     then 'Negada pela regulação'
        when 'agendada'   then 'Agendada'
        when 'realizada'  then 'Atendimento realizado'
        when 'faltou'     then 'Falta registrada'
        when 'cancelada'  then 'Cancelada'
        else s.status::text
      end,
      s.exige_regulacao,
      s.proc_nome,
      s.data_pedido,
      (current_date - s.data_pedido),
      v_pos,
      s.vdata, s.vhora, s.uenome, s.ueend, s.uetel,
      case when s.status in ('devolvida','negada') then s.parecer end;
  end loop;

  if not achou then
    insert into consultas_publicas (protocolo, sucesso) values (v_prot, false);
    -- Resposta idêntica para protocolo que não existe e para data que não
    -- confere. Distinguir os dois confirmaria a existência do protocolo.
    return query select 'nao_encontrado'::text, null::text, null::text, null::boolean, null::text,
                        null::date, null::int, null::int, null::date, null::time,
                        null::text, null::text, null::text, null::text;
    return;
  end if;

  insert into consultas_publicas (protocolo, sucesso) values (v_prot, true);
end $$;

revoke all on function consultar_protocolo(text, date)  from public;
grant execute on function consultar_protocolo(text, date) to anon, authenticated;

-- ---------------------------------------------------------------------
--  3. O MIRA PRECISA DE IDENTIFICADOR PRÓPRIO POR REGISTRO
--
--  Com o protocolo compartilhado, oito exames iriam ao Ministério com o
--  mesmo identificador de registro, e lá não dá para saber qual é qual.
-- ---------------------------------------------------------------------
drop function if exists mira_lote(date, date);
drop view if exists vw_mira;
create view vw_mira with (security_invoker = true) as
select
  -- Identificador único por registro. O protocolo deixou de servir sozinho:
  -- os exames de um mesmo pedido de laboratório compartilham um, e o MIRA
  -- exige que cada registro enviado tenha identificador próprio.
  s.protocolo || '-' || s.id                    as identificador_registro,
  mira_status(s.status)                         as status_solicitacao,
  pr.codigo_sigtap                              as codigo_procedimento,
  s.created_at                                  as data_solicitacao,
  s.data_regulacao                              as data_autorizacao,
  s.data_execucao                               as data_execucao,
  coalesce(p.cns, p.cpf)                        as identificador_paciente,
  case when p.cns is not null then 'cns' else 'cpf' end as tipo_identificador_paciente,
  us.cnes                                       as cnes_solicitante,
  (select u2.cnes from unidades u2 where u2.reguladora order by u2.id limit 1) as cnes_regulador,
  ue.cnes                                       as cnes_executante,
  -- O CBO do profissional que executa é o que o modelo pede; o do
  -- procedimento fica como recurso para vaga sem profissional cadastrado.
  coalesce(prof.cbo, pr.cbo)                    as cbo_executante,
  pr.modalidade                                 as modalidade_assistencial,
  mira_caracter(s.prioridade)                   as caracter_solicitacao,
  s.cid10                                       as motivo_solicitacao,
  s.id                                          as solicitacao_id,
  s.updated_at                                  as atualizado_em
from solicitacoes s
join pacientes     p  on p.id  = s.paciente_id
join procedimentos pr on pr.id = s.procedimento_id
join unidades      us on us.id = s.unidade_solicitante_id
left join vagas    v  on v.id  = s.vaga_id
left join unidades ue on ue.id = v.unidade_executante_id
left join profissionais prof on prof.id = v.profissional_id;

create or replace function mira_lote(p_de date default null, p_ate date default null)
returns setof vw_mira
language sql stable security definer set search_path = public as $$
  select * from vw_mira
   where codigo_procedimento is not null
     and identificador_paciente is not null
     and cnes_solicitante is not null
     and motivo_solicitacao is not null
     and (p_de  is null or atualizado_em::date >= p_de)
     and (p_ate is null or atualizado_em::date <= p_ate)
   order by atualizado_em
$$;

do $$
declare fn regprocedure;
begin
 for fn in select p.oid::regprocedure from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public' and p.proname in ('mira_lote')
 loop
   execute format('revoke all on function %s from public, anon', fn);
   execute format('grant execute on function %s to authenticated', fn);
 end loop;
end $$;

-- MIGRACAO-009-FIM
