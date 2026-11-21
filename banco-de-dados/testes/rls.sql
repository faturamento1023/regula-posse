-- =====================================================================
--  TESTES DE RLS (isolamento entre unidades e perfis)
--
--  POR QUE ESTE ARQUIVO EXISTE SEPARADO:
--  os testes de fluxo.sql rodam como DONO das tabelas, e no Postgres o
--  dono ignora row level security. Eles verificam regra de negócio e
--  grants, mas NÃO verificam as políticas — foi um ponto cego: uma
--  política errada passaria despercebida por eles.
--
--  Aqui todo teste de visibilidade roda com `set role authenticated`,
--  que é o papel que o cliente usa de verdade, com auth.uid() apontando
--  para o usuário em questão. O preparo dos dados continua sendo feito
--  como dono, de propósito.
--
--  Local:  psql -f ferramentas/stub-supabase.sql -f banco-de-dados/schema.sql \
--               -f banco-de-dados/testes/rls.sql
-- =====================================================================
\set ON_ERROR_STOP on

-- ---------- preparo, como dono ----------
insert into auth.users (id, email) values
  ('aaaaaaaa-0000-0000-0000-000000000001', 'adm@teste'),
  ('aaaaaaaa-0000-0000-0000-000000000002', 'ubsa@teste'),
  ('aaaaaaaa-0000-0000-0000-000000000003', 'ubsb@teste'),
  ('aaaaaaaa-0000-0000-0000-000000000004', 'exec@teste');

insert into unidades (nome, tipo, cnes) values
  ('UBS A', 'solicitante', '1110000'),
  ('UBS B', 'solicitante', '2220000'),
  ('Hospital', 'executante', '3330000');
insert into procedimentos (nome, tipo, ativo) values ('Consulta teste', 'consulta', true);
insert into pacientes (nome, cpf, data_nascimento, sexo, unidade_referencia_id)
  values ('Paciente da A', '01234567890', '1980-01-01', 'F', 1),
         ('Paciente da B', '01358024588', '1985-01-01', 'M', 2);

update perfis set papel='admin',       ativo=true, nome='Adm'  where id='aaaaaaaa-0000-0000-0000-000000000001';
update perfis set papel='solicitante', ativo=true, nome='A',  unidade_id=1 where id='aaaaaaaa-0000-0000-0000-000000000002';
update perfis set papel='solicitante', ativo=true, nome='B',  unidade_id=2 where id='aaaaaaaa-0000-0000-0000-000000000003';
update perfis set papel='executante',  ativo=true, nome='Ex', unidade_id=3 where id='aaaaaaaa-0000-0000-0000-000000000004';

insert into solicitacoes (paciente_id, procedimento_id, unidade_solicitante_id, data_pedido, cid10)
  values (1, 1, 1, current_date, 'I10'),   -- id 1, da UBS A
         (2, 1, 2, current_date, 'I10');   -- id 2, da UBS B
insert into anexos (solicitacao_id, caminho, nome_original, tipo, tamanho)
  values (1, '1/pedido.pdf', 'pedido.pdf', 'application/pdf', 1000),
         (2, '2/pedido.pdf', 'pedido.pdf', 'application/pdf', 1000);

-- ---------- utilitário ----------
create or replace function teste_conta(p_usuario uuid, p_sql text)
returns bigint language plpgsql as $$
declare n bigint;
begin
  perform set_config('request.jwt.claim.sub', p_usuario::text, true);
  set local role authenticated;
  execute p_sql into n;
  return n;
end $$;

-- ---------- solicitações: cada unidade vê a sua ----------
do $$
declare a uuid := 'aaaaaaaa-0000-0000-0000-000000000002';
        b uuid := 'aaaaaaaa-0000-0000-0000-000000000003';
        adm uuid := 'aaaaaaaa-0000-0000-0000-000000000001';
        ex uuid := 'aaaaaaaa-0000-0000-0000-000000000004';
begin
  if teste_conta(a, 'select count(*) from solicitacoes') <> 1 then
    raise exception 'a UBS A devia ver exatamente a solicitação dela';
  end if;
  if teste_conta(b, 'select count(*) from solicitacoes') <> 1 then
    raise exception 'a UBS B devia ver exatamente a solicitação dela';
  end if;
  if teste_conta(a, 'select count(*) from solicitacoes where id = 2') <> 0 then
    raise exception 'a UBS A NÃO devia ver a solicitação da UBS B';
  end if;
  if teste_conta(adm, 'select count(*) from solicitacoes') <> 2 then
    raise exception 'o administrador devia ver as duas';
  end if;
  -- executante só vê o que está agendado no local dele; nada está
  if teste_conta(ex, 'select count(*) from solicitacoes') <> 0 then
    raise exception 'o executante não devia ver solicitação sem vaga no local dele';
  end if;
end $$;

-- ---------- anexos seguem a visibilidade da solicitação ----------
do $$
declare a uuid := 'aaaaaaaa-0000-0000-0000-000000000002';
        b uuid := 'aaaaaaaa-0000-0000-0000-000000000003';
        adm uuid := 'aaaaaaaa-0000-0000-0000-000000000001';
begin
  if teste_conta(a, 'select count(*) from anexos') <> 1 then
    raise exception 'a UBS A devia ver só o anexo dela';
  end if;
  if teste_conta(a, 'select count(*) from anexos where solicitacao_id = 2') <> 0 then
    raise exception 'a UBS A NÃO devia ver o anexo da UBS B';
  end if;
  if teste_conta(adm, 'select count(*) from anexos') <> 2 then
    raise exception 'o administrador devia ver os dois anexos';
  end if;
  -- e o mesmo vale para a função que o Storage usa
  if teste_conta(a, 'select count(*) from (select pode_ver_anexo(''2/pedido.pdf'') as v) t where t.v') <> 0 then
    raise exception 'pode_ver_anexo devia recusar arquivo de outra unidade';
  end if;
  if teste_conta(a, 'select count(*) from (select pode_anexar(''2/x.pdf'') as v) t where t.v') <> 0 then
    raise exception 'pode_anexar devia recusar caminho de outra unidade';
  end if;
  if teste_conta(a, 'select count(*) from (select pode_anexar(''1/x.pdf'') as v) t where t.v') <> 1 then
    raise exception 'pode_anexar devia permitir na própria solicitação';
  end if;
end $$;

-- ---------- histórico segue a solicitação ----------
do $$
declare a uuid := 'aaaaaaaa-0000-0000-0000-000000000002';
begin
  if teste_conta(a, 'select count(*) from historico where solicitacao_id = 2') <> 0 then
    raise exception 'a UBS A NÃO devia ver histórico de solicitação de outra unidade';
  end if;
  if teste_conta(a, 'select count(*) from historico where solicitacao_id = 1') = 0 then
    raise exception 'a UBS A devia ver o histórico da própria solicitação';
  end if;
end $$;

-- ---------- auditoria e logs: só administrador ----------
do $$
declare a uuid := 'aaaaaaaa-0000-0000-0000-000000000002';
        adm uuid := 'aaaaaaaa-0000-0000-0000-000000000001';
begin
  update pacientes set telefone = '62999990000' where id = 1;   -- gera auditoria
  perform registrar_acesso_paciente(1, 'teste');

  if teste_conta(a, 'select count(*) from historico_paciente') <> 0 then
    raise exception 'quem não é administrador não devia ver auditoria de paciente';
  end if;
  if teste_conta(adm, 'select count(*) from historico_paciente') = 0 then
    raise exception 'o administrador devia ver a auditoria de paciente';
  end if;
  if teste_conta(a, 'select count(*) from acessos_paciente') <> 0 then
    raise exception 'quem não é administrador não devia ver o log de acesso';
  end if;
  if teste_conta(a, 'select count(*) from consultas_publicas') <> 0 then
    raise exception 'quem não é administrador não devia ver as tentativas de consulta pública';
  end if;
end $$;

-- ---------- perfis: cada um vê o seu ----------
do $$
declare a uuid := 'aaaaaaaa-0000-0000-0000-000000000002';
        adm uuid := 'aaaaaaaa-0000-0000-0000-000000000001';
begin
  if teste_conta(a, 'select count(*) from perfis') <> 1 then
    raise exception 'quem não é administrador devia ver só o próprio perfil';
  end if;
  if teste_conta(adm, 'select count(*) from perfis') < 4 then
    raise exception 'o administrador devia ver todos os perfis';
  end if;
end $$;

-- ---------- pacientes ----------
do $$
declare b uuid := 'aaaaaaaa-0000-0000-0000-000000000003';
begin
  -- a UBS B enxerga o paciente dela e o da A apenas através da solicitação
  -- que ela não vê, logo: só o dela
  if teste_conta(b, 'select count(*) from pacientes where id = 1') <> 0 then
    raise exception 'a UBS B NÃO devia ver o paciente de referência da UBS A';
  end if;
  if teste_conta(b, 'select count(*) from pacientes where id = 2') <> 1 then
    raise exception 'a UBS B devia ver o paciente de referência dela';
  end if;
end $$;

drop function teste_conta(uuid, text);
select 'TESTES DE RLS PASSARAM' as resultado;
