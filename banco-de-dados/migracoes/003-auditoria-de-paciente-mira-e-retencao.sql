-- =====================================================================
--  MIGRAÇÃO 003 — auditoria do cadastro de paciente, log de acesso,
--                 exportação MIRA e política de retenção
--  ---------------------------------------------------------------------
--  Para bancos já em produção: Supabase > SQL Editor > cole e execute.
--  Em banco novo não é preciso: o mesmo conteúdo está em schema.sql.
--  Pode ser executado mais de uma vez.
-- =====================================================================

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

grant select on vw_mira to authenticated;

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
