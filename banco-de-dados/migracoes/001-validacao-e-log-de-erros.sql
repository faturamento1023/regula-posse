-- =====================================================================
--  MIGRAÇÃO 001 — validação de CPF/CNS no banco e log de erro
--  ---------------------------------------------------------------------
--  Para bancos já em produção: Supabase > SQL Editor > cole e execute.
--  Em banco novo não é preciso: este mesmo conteúdo já está em
--  banco-de-dados/schema.sql, na seção 10. Os dois arquivos têm o bloco
--  idêntico de propósito, e o CI confere que continuam iguais
--  (ferramentas/verificar-migracoes.mjs).
--
--  Pode ser executado mais de uma vez.
-- =====================================================================

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
