-- =====================================================================
--  MIGRAÇÃO 002 — auditoria da regulação, correções de fluxo,
--                 vulnerabilidade e transparência ao usuário
--  ---------------------------------------------------------------------
--  Para bancos já em produção: Supabase > SQL Editor > cole e execute.
--  Em banco novo não é preciso: o mesmo conteúdo está em schema.sql.
--  Pode ser executado mais de uma vez.
-- =====================================================================

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
