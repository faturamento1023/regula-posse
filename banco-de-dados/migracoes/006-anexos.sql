-- =====================================================================
--  MIGRAÇÃO 006 — anexos da solicitação (pedido médico e exames)
--  ---------------------------------------------------------------------
--  Para bancos já em produção: Supabase > SQL Editor > cole e execute.
--  Cria o bucket privado "anexos" e as políticas de acesso a ele.
--  Pode ser executado mais de uma vez.
-- =====================================================================

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
drop view if exists vw_solicitacoes cascade;
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
 where n.nspname = 'public' and p.proname in ('pode_ver_anexo','pode_anexar','sol_do_caminho','mira_lote')
 loop
   execute format('revoke all on function %s from public, anon', fn);
   execute format('grant execute on function %s to authenticated', fn);
 end loop;
end $$;

-- MIGRACAO-006-FIM
