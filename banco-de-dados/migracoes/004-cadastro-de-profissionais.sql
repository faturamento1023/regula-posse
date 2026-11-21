-- =====================================================================
--  MIGRAÇÃO 004 — cadastro de profissionais executantes
--  ---------------------------------------------------------------------
--  Para bancos já em produção: Supabase > SQL Editor > cole e execute.
--  Em banco novo não é preciso: o mesmo conteúdo está em schema.sql.
--  Pode ser executado mais de uma vez.
-- =====================================================================

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

grant select on vw_mira to authenticated;

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
 where n.nspname = 'public' and p.proname in ('gerar_vagas','mira_lote')
 loop
   execute format('revoke all on function %s from public, anon', fn);
   execute format('grant execute on function %s to authenticated', fn);
 end loop;
end $$;

-- MIGRACAO-004-FIM
