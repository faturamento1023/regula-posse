-- =====================================================================
--  REGULA POSSE — Sistema de Regulação Municipal  (versão 4)
--  Banco de dados: Supabase (PostgreSQL)
--
--  Como usar: Supabase > SQL Editor > New query > cole este arquivo > Run
--  Pode ser executado mais de uma vez; também atualiza bancos das versões 1 e 2.
--  Versão 4: procedimentos.exige_regulacao, consultar_guia(), agendar() respeita a regulação.
--  Versão 5: validação de CPF e CNS no banco, tabela de log de erro.
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
