-- MIGRAÇÃO 010 — códigos SIGTAP de referência sem duplicar catálogo oficial
-- 42 exames internos podem manter nomes próprios e apontar para a entrada oficial
-- por meio da referência, preservando a restrição única codigo_sigtap.
-- Aplicar somente após a migração 009.
-- MIGRACAO-010-INICIO

alter table public.procedimentos
  add column if not exists codigo_sigtap_referencia text;

comment on column public.procedimentos.codigo_sigtap_referencia is
  'Código SIGTAP oficial correspondente ao procedimento interno. Mantém o nome e o ID do procedimento local sem duplicar a entrada oficial do catálogo.';

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conrelid='public.procedimentos'::regclass
      and conname='procedimentos_sigtap_referencia_fk'
  ) then
    alter table public.procedimentos
      add constraint procedimentos_sigtap_referencia_fk
      foreign key (codigo_sigtap_referencia)
      references public.procedimentos(codigo_sigtap)
      on update cascade on delete set null;
  end if;
end $$;

-- Na exportação MIRA, usa o código oficial ou, para procedimento interno,
-- a referência validada contra o catálogo SIGTAP. Os nomes são preservados.
create or replace view vw_mira with (security_invoker = true) as
select
  -- Identificador único por registro. O protocolo deixou de servir sozinho:
  -- os exames de um mesmo pedido de laboratório compartilham um, e o MIRA
  -- exige que cada registro enviado tenha identificador próprio.
  s.protocolo || '-' || s.id                    as identificador_registro,
  mira_status(s.status)                         as status_solicitacao,
  coalesce(pr.codigo_sigtap, pr.codigo_sigtap_referencia) as codigo_procedimento,
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

-- A conferência do MIRA também considera a referência oficial validada.
CREATE OR REPLACE FUNCTION public.mira_pendencias()
 RETURNS TABLE(problema text, solicitacoes bigint, como_resolver text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
     where coalesce(nullif(trim(pr.codigo_sigtap), ''), nullif(trim(pr.codigo_sigtap_referencia), '')) is null
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
$function$


-- MIGRACAO-010-FIM
