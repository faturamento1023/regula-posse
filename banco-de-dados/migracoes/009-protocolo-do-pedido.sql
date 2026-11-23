-- =====================================================================
--  MIGRAÇÃO 009 — um protocolo para o pedido de laboratório
--  ---------------------------------------------------------------------
--  Para bancos já em produção: Supabase > SQL Editor > cole e execute.
--  Depende da migração 008. Pode ser executado mais de uma vez.
-- =====================================================================

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
