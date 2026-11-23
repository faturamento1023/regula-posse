-- =====================================================================
--  MIGRAÇÃO 008 — agenda diária de laboratório
--  ---------------------------------------------------------------------
--  Para bancos já em produção: Supabase > SQL Editor > cole e execute.
--  Pode ser executado mais de uma vez.
-- =====================================================================

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
