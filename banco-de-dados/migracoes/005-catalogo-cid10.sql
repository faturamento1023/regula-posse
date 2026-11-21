-- =====================================================================
--  MIGRAÇÃO 005 — catálogo CID-10
--  ---------------------------------------------------------------------
--  Para bancos já em produção: Supabase > SQL Editor > cole e execute.
--  Depois, aplique os lotes de data/cid10/ gerados pelo workflow
--  "Preparar CID-10". Sem eles a tabela fica vazia e o campo continua
--  aceitando digitação livre, como antes.
--  Pode ser executado mais de uma vez.
-- =====================================================================

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
