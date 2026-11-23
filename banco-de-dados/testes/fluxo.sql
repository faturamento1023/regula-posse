-- =====================================================================
--  TESTES DO FLUXO DE REGULAÇÃO
--  Rodam no CI, contra um Postgres limpo com o stub do Supabase, depois
--  de aplicar schema.sql. Cada bloco falha com mensagem própria, então o
--  CI aponta exatamente a regra que quebrou.
--
--  Local:  psql -f ferramentas/stub-supabase.sql -f banco-de-dados/schema.sql \
--               -f banco-de-dados/testes/fluxo.sql
-- =====================================================================
\set ON_ERROR_STOP on

-- ---------- cenário ----------
insert into auth.users (id, email) values ('11111111-1111-1111-1111-111111111111', 'reg@teste');
update perfis set papel = 'admin', ativo = true, nome = 'Regulador Teste'
 where id = '11111111-1111-1111-1111-111111111111';
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', false);

insert into unidades (nome, tipo) values ('UBS Teste', 'solicitante'), ('Hospital Teste', 'executante');
insert into procedimentos (nome, tipo, exige_regulacao, ativo) values ('Consulta teste', 'consulta', true, true);
insert into pacientes (nome, cpf, data_nascimento, sexo) values ('Paciente Teste', '01234567890', '1980-03-05', 'F');
insert into solicitacoes (paciente_id, procedimento_id, unidade_solicitante_id, prioridade, justificativa, data_pedido)
values (1, 1, 1, 'azul', 'justificativa original', current_date - 40);

-- ---------- as duas esperas ----------
do $$
declare r record;
begin
  select dias_espera, dias_desde_pedido, dias_ate_insercao into r from vw_solicitacoes where id = 1;
  if r.dias_espera <> 0 then raise exception 'dias_espera devia contar do lançamento: %', r.dias_espera; end if;
  if r.dias_desde_pedido <> 40 then raise exception 'dias_desde_pedido devia ser 40: %', r.dias_desde_pedido; end if;
  if r.dias_ate_insercao <> 40 then raise exception 'dias_ate_insercao devia ser 40: %', r.dias_ate_insercao; end if;
end $$;

-- ---------- reclassificação de risco fica registrada ----------
do $$
declare r record;
begin
  perform regular_solicitacao(1, 'autorizar', 'vermelho', 'risco alto');
  select prioridade_anterior, prioridade_nova, usuario_id into r
    from historico where solicitacao_id = 1 order by id desc limit 1;
  if r.prioridade_anterior <> 'azul' or r.prioridade_nova <> 'vermelho' then
    raise exception 'a reclassificação de risco não foi registrada (de % para %)',
      r.prioridade_anterior, r.prioridade_nova;
  end if;
  if r.usuario_id is null then raise exception 'o histórico não registrou quem reclassificou'; end if;
end $$;

-- ---------- autorização pode ser revista, com parecer ----------
do $$
begin
  begin
    perform regular_solicitacao(1, 'devolver', null, '');
    raise exception 'devolver sem parecer devia falhar';
  exception when others then
    if sqlerrm = 'devolver sem parecer devia falhar' then raise; end if;
  end;
  perform regular_solicitacao(1, 'devolver', null, 'faltou exame');
  if (select status from solicitacoes where id = 1) <> 'devolvida' then
    raise exception 'a autorização não foi revista';
  end if;
end $$;

-- ---------- reenvio preserva a justificativa anterior ----------
do $$
begin
  perform reenviar_solicitacao(1, 'justificativa corrigida com exame');
  if not exists (select 1 from historico
                  where solicitacao_id = 1 and justificativa_anterior = 'justificativa original') then
    raise exception 'a justificativa anterior não foi preservada no histórico';
  end if;
end $$;

-- ---------- procedimento que exige regulação não pode ser agendado direto ----------
insert into vagas (unidade_executante_id, procedimento_id, data, hora, status)
values (2, 1, current_date + 5, '09:00', 'livre'), (2, 1, current_date + 12, '10:00', 'livre');
do $$
begin
  begin
    perform agendar(1, 1);
    raise exception 'agendar sem autorização devia falhar';
  exception when others then
    if sqlerrm = 'agendar sem autorização devia falhar' then raise; end if;
  end;
end $$;

-- ---------- reagendamento após falta ----------
do $$
declare v_guia text;
begin
  perform regular_solicitacao(1, 'autorizar', null, 'ok');
  v_guia := agendar(1, 1);
  perform confirmar_atendimento(v_guia, 'faltou', 'não compareceu');
  if (select status from solicitacoes where id = 1) <> 'faltou' then
    raise exception 'a falta não foi registrada';
  end if;

  begin
    perform agendar(1, 2);
    raise exception 'reagendar sem motivo devia falhar';
  exception when others then
    if sqlerrm = 'reagendar sem motivo devia falhar' then raise; end if;
  end;

  if agendar(1, 2, 'paciente justificou a ausência') <> v_guia then
    raise exception 'o reagendamento devia manter a mesma guia';
  end if;
  if (select status from solicitacoes where id = 1) <> 'agendada' then
    raise exception 'o reagendamento não voltou para agendada';
  end if;
  -- o desfecho anterior tem de ser limpo, senão a falta antiga fica grudada
  if (select data_execucao from solicitacoes where id = 1) is not null then
    raise exception 'o reagendamento devia limpar a execução anterior';
  end if;
  -- a vaga da falta NÃO volta para a oferta: foi consumida
  if (select status from vagas where id = 1) <> 'ocupada' then
    raise exception 'a vaga da falta não devia ser liberada';
  end if;
end $$;

-- ---------- vulnerabilidade: inerte sem critério cadastrado ----------
do $$
begin
  if (select peso_vulnerabilidade from vw_solicitacoes where id = 1) <> 0 then
    raise exception 'sem critério cadastrado, o peso devia ser zero';
  end if;
  insert into criterios_vulnerabilidade (nome, peso) values ('Área rural de difícil acesso', 4);
  insert into solicitacao_vulnerabilidade (solicitacao_id, criterio_id) values (1, 1);
  if (select peso_vulnerabilidade from vw_solicitacoes where id = 1) <> 4 then
    raise exception 'o peso do critério não entrou na view';
  end if;
  if not ((select vulnerabilidades from vw_solicitacoes where id = 1) @> array['Área rural de difícil acesso']) then
    raise exception 'o nome do critério não aparece na view';
  end if;
end $$;

-- ---------- acompanhamento público ----------
do $$
declare r record; i int;
begin
  -- protocolo certo com data certa
  select * into r from consultar_protocolo((select protocolo from solicitacoes where id = 1), '1980-03-05');
  if r.resultado <> 'ok' then raise exception 'a consulta pública devia encontrar: %', r.resultado; end if;
  if r.dias_desde_pedido <> 40 then raise exception 'a consulta devia contar do pedido médico'; end if;

  -- data errada e protocolo inexistente têm de dar a MESMA resposta
  select * into r from consultar_protocolo((select protocolo from solicitacoes where id = 1), '1990-01-01');
  if r.resultado <> 'nao_encontrado' then raise exception 'data errada devia dar nao_encontrado'; end if;
  select * into r from consultar_protocolo('2026999999', '1980-03-05');
  if r.resultado <> 'nao_encontrado' then raise exception 'protocolo inexistente devia dar nao_encontrado'; end if;

  -- trava de volume. Isto só funciona porque a função devolve o erro em
  -- "resultado" em vez de usar raise: raise desfaria a transação e
  -- apagaria o registro da tentativa, deixando a trava sem efeito.
  delete from consultas_publicas;
  for i in 1..10 loop
    select * into r from consultar_protocolo('2026000001', '1990-01-01');
    if r.resultado <> 'nao_encontrado' then
      raise exception 'tentativa % devia passar, deu %', i, r.resultado;
    end if;
  end loop;
  select * into r from consultar_protocolo('2026000001', '1990-01-01');
  if r.resultado <> 'limite' then
    raise exception 'a 11a tentativa devia bater na trava de volume, deu %', r.resultado;
  end if;
  if (select count(*) from consultas_publicas) <> 11 then
    raise exception 'as tentativas não foram registradas: %', (select count(*) from consultas_publicas);
  end if;
end $$;

-- ---------- o papel anônimo não alcança nenhum dado pessoal ----------
do $$
declare t text;
begin
  foreach t in array array['pacientes','solicitacoes','historico','consultas_publicas','vagas','perfis','erros'] loop
    if has_table_privilege('anon', 'public.' || t, 'SELECT') then
      raise exception 'anon não devia ter SELECT em %', t;
    end if;
  end loop;
  if not has_function_privilege('anon', 'public.consultar_protocolo(text,date)', 'EXECUTE') then
    raise exception 'anon precisa executar consultar_protocolo';
  end if;
  if not has_function_privilege('anon', 'public.tempos_medios_espera()', 'EXECUTE') then
    raise exception 'anon precisa executar tempos_medios_espera';
  end if;
  if has_function_privilege('anon', 'public.agendar(bigint,bigint,text)', 'EXECUTE') then
    raise exception 'anon não devia executar agendar';
  end if;
end $$;

-- ---------- painel agregado conta só quem está esperando ----------
-- A solicitação 1 já foi agendada, então o painel tem de estar vazio: ele
-- mede fila, não produção.
do $$
begin
  if exists (select 1 from tempos_medios_espera()) then
    raise exception 'o painel não devia contar solicitação já agendada';
  end if;
end $$;

insert into solicitacoes (paciente_id, procedimento_id, unidade_solicitante_id, prioridade, data_pedido)
values (1, 1, 1, 'verde', current_date - 10);

do $$
declare r record;
begin
  select * into r from tempos_medios_espera() limit 1;
  if r.procedimento <> 'Consulta teste' then raise exception 'o painel devia listar o procedimento'; end if;
  if r.aguardando <> 1 then raise exception 'devia haver 1 aguardando, há %', r.aguardando; end if;
  if r.espera_media_dias <> 10.0 then
    raise exception 'a espera média devia contar do pedido médico (10), deu %', r.espera_media_dias;
  end if;
end $$;

select 'TODOS OS TESTES DE FLUXO PASSARAM' as resultado;

-- =====================================================================
--  AUDITORIA DE PACIENTE, LOG DE ACESSO, MIRA E RETENÇÃO (migração 003)
-- =====================================================================

-- ---------- alteração em paciente deixa rastro ----------
do $$
declare n int;
begin
  update pacientes set telefone = '62988776655' where id = 1;
  select count(*) into n from historico_paciente
   where paciente_id = 1 and campo = 'telefone' and valor_novo = '62988776655' and usuario_id is not null;
  if n <> 1 then raise exception 'a alteração de telefone não foi auditada'; end if;

  -- campo que não mudou não gera linha
  update pacientes set telefone = '62988776655' where id = 1;
  select count(*) into n from historico_paciente where paciente_id = 1 and campo = 'telefone';
  if n <> 1 then raise exception 'update sem mudança real não devia gerar auditoria'; end if;

  -- o trigger é genérico: pega qualquer coluna, inclusive as que não existiam
  update pacientes set nome_mae = 'Mãe Teste' where id = 1;
  if not exists (select 1 from historico_paciente where campo = 'nome_mae') then
    raise exception 'o trigger devia auditar qualquer coluna';
  end if;
end $$;

-- ---------- log de acesso, com deduplicação ----------
do $$
declare n int;
begin
  perform registrar_acesso_paciente(1, 'ficha do paciente');
  perform registrar_acesso_paciente(1, 'ficha do paciente');
  select count(*) into n from acessos_paciente where paciente_id = 1 and contexto = 'ficha do paciente';
  if n <> 1 then raise exception 'acessos repetidos na mesma janela deviam virar um registro só, vieram %', n; end if;

  perform registrar_acesso_paciente(1, 'impressao de guia');
  select count(*) into n from acessos_paciente where paciente_id = 1;
  if n <> 2 then raise exception 'contexto diferente devia gerar registro próprio'; end if;
end $$;

-- ---------- MIRA ----------
do $$
declare r record; n int;
begin
  -- sem CNES na unidade e sem código SIGTAP, o registro não pode ser enviado
  update unidades set cnes = null where id = 1;
  if not exists (select 1 from mira_pendencias() where problema like '%CNES%') then
    raise exception 'mira_pendencias devia apontar a falta de CNES';
  end if;
  select count(*) into n from mira_lote();
  if n <> 0 then raise exception 'o lote não devia incluir registro sem CNES'; end if;

  -- completando o cadastro
  update unidades set cnes = '1234567' where id = 1;
  update unidades set cnes = '9999999', reguladora = true where id = 2;
  update procedimentos set codigo_sigtap = '0301010072', cbo = '225120' where id = 1;
  update solicitacoes set cid10 = 'I20.0';

  select * into r from vw_mira where solicitacao_id = 1;
  if r.codigo_procedimento <> '0301010072' then raise exception 'código SIGTAP errado no MIRA'; end if;
  if r.cnes_solicitante <> '1234567' then raise exception 'CNES do solicitante errado'; end if;
  if r.cnes_regulador <> '9999999' then raise exception 'CNES do regulador errado'; end if;
  if r.motivo_solicitacao <> 'I20.0' then raise exception 'CID-10 não chegou ao MIRA'; end if;
  if r.identificador_paciente is null then raise exception 'o paciente precisa de CPF ou CNS'; end if;
  if r.modalidade_assistencial <> 'ambulatorial' then raise exception 'modalidade errada'; end if;
end $$;

-- ---------- mapeamentos do MIRA ----------
do $$
begin
  -- quatro níveis de risco viram dois caracteres
  if mira_caracter('vermelho') <> 'urgencia' or mira_caracter('amarelo') <> 'urgencia' then
    raise exception 'vermelho e amarelo deviam mapear para urgência';
  end if;
  if mira_caracter('verde') <> 'eletivo' or mira_caracter('azul') <> 'eletivo' then
    raise exception 'verde e azul deviam mapear para eletivo';
  end if;
  -- oito status viram sete situações do modelo
  if mira_status('pendente') <> 'pendente' or mira_status('autorizada') <> 'pendente' then
    raise exception 'pendente e autorizada deviam mapear para pendente';
  end if;
  if mira_status('negada') <> 'negado_cancelado' or mira_status('cancelada') <> 'negado_cancelado' then
    raise exception 'negada e cancelada deviam mapear para negado_cancelado';
  end if;
  if mira_status('devolvida') <> 'devolvido_solicitante' then raise exception 'devolvida mapeia errado'; end if;
  if mira_status('realizada') <> 'atendido' then raise exception 'realizada mapeia errado'; end if;
  if mira_status('faltou') <> 'falta' then raise exception 'faltou mapeia errado'; end if;
end $$;

-- ---------- retenção não encosta em registro assistencial ----------
do $$
declare r record; antes bigint;
begin
  select count(*) into antes from solicitacoes;
  insert into acessos_paciente (paciente_id, usuario_id, contexto, created_at)
  values (1, null, 'antigo', now() - interval '800 days');
  for r in select * from aplicar_retencao() loop null; end loop;
  if exists (select 1 from acessos_paciente where contexto = 'antigo') then
    raise exception 'a retenção devia apagar o acesso de 800 dias';
  end if;
  if (select count(*) from solicitacoes) <> antes then
    raise exception 'a retenção NUNCA pode apagar solicitação';
  end if;
  if not exists (select 1 from historico_paciente) then
    raise exception 'a retenção NUNCA pode apagar auditoria de paciente';
  end if;
end $$;

-- ---------- anon continua sem alcançar nada disso ----------
do $$
declare t text;
begin
  foreach t in array array['historico_paciente','acessos_paciente','politica_retencao','vw_mira'] loop
    if has_table_privilege('anon', 'public.' || t, 'SELECT') then
      raise exception 'anon não devia ter SELECT em %', t;
    end if;
  end loop;
end $$;

select 'TESTES DA MIGRAÇÃO 003 PASSARAM' as resultado;

-- =====================================================================
--  CADASTRO DE PROFISSIONAIS (migração 004)
-- =====================================================================
do $$
declare r jsonb; n int;
begin
  insert into profissionais (nome, conselho, numero_conselho, uf_conselho, cbo, especialidade, unidade_id)
  values ('Dr. Teste Executante', 'CRM', '12345', 'GO', '225120', 'Cardiologia', 2);

  -- o mesmo registro de conselho não pode entrar duas vezes
  begin
    insert into profissionais (nome, conselho, numero_conselho, uf_conselho)
    values ('Outro Nome', 'CRM', '12345', 'GO');
    raise exception 'conselho duplicado devia ser recusado';
  exception when unique_violation then null;
  end;

  -- mas dois sem número de registro convivem
  insert into profissionais (nome, conselho) values ('Sem Registro A', 'CRM');
  insert into profissionais (nome, conselho) values ('Sem Registro B', 'CRM');

  -- gerar_vagas mantém o formato de retorno do original e copia o nome
  r := gerar_vagas(2, 1, 1, array[current_date + 30],
         '[{"hora_ini":"08:00","hora_fim":"10:00","intervalo":30,"qtd":1}]'::jsonb);
  if (r->>'vagas')::int <> 4 then raise exception 'esperadas 4 vagas, vieram %', r->>'vagas'; end if;
  if r->'ignoradas' is null then raise exception 'o retorno perdeu o campo ignoradas'; end if;

  select count(*) into n from vagas
   where profissional_id = 1 and profissional = 'Dr. Teste Executante' and data = current_date + 30;
  if n <> 4 then raise exception 'a vaga devia guardar o id e o nome do profissional'; end if;

  -- intervalo zero continua criando todas no mesmo horário
  r := gerar_vagas(2, 1, 1, array[current_date + 31],
         '[{"hora_ini":"13:00","hora_fim":"13:00","intervalo":0,"qtd":5}]'::jsonb);
  if (r->>'vagas')::int <> 5 then raise exception 'mutirão devia criar 5 vagas, criou %', r->>'vagas'; end if;

  -- repetir a data devolve a data em ignoradas, sem duplicar vaga
  r := gerar_vagas(2, 1, 1, array[current_date + 30],
         '[{"hora_ini":"08:00","hora_fim":"09:00","intervalo":30,"qtd":1}]'::jsonb);
  if jsonb_array_length(r->'ignoradas') <> 1 then raise exception 'data repetida devia ser ignorada'; end if;

  -- profissional inativo ou inexistente é recusado
  update profissionais set ativo = false where id = 2;
  begin
    perform gerar_vagas(2, 1, 2, array[current_date + 40],
              '[{"hora_ini":"08:00","hora_fim":"09:00","intervalo":30,"qtd":1}]'::jsonb);
    raise exception 'profissional inativo devia ser recusado';
  exception when others then
    if sqlerrm = 'profissional inativo devia ser recusado' then raise; end if;
  end;
end $$;

-- o MIRA passa a usar o CBO do profissional, não o do procedimento
do $$
declare r record;
begin
  update procedimentos set cbo = '999999' where id = 1;
  update solicitacoes set vaga_id = (select id from vagas where profissional_id = 1 limit 1) where id = 1;
  select * into r from vw_mira where solicitacao_id = 1;
  if r.cbo_executante <> '225120' then
    raise exception 'o CBO devia vir do profissional (225120), veio %', r.cbo_executante;
  end if;
end $$;

select 'TESTES DA MIGRAÇÃO 004 PASSARAM' as resultado;

-- =====================================================================
--  CATÁLOGO CID-10 (migração 005)
-- =====================================================================
do $$
begin
  -- Catálogo vazio: aceita o que tem formato de CID e recusa o resto. É o
  -- que permite aplicar a migração antes de importar os lotes sem travar o
  -- registro de solicitação na recepção.
  if not cid10_valido('I20')   then raise exception 'catálogo vazio devia aceitar I20'; end if;
  if not cid10_valido('I20.0') then raise exception 'catálogo vazio devia aceitar I20.0'; end if;
  if not cid10_valido('')      then raise exception 'vazio é tratado por quem chama'; end if;
  if cid10_valido('I20.O')     then raise exception 'letra O no lugar do zero devia ser recusada'; end if;
  if cid10_valido('X')         then raise exception 'código curto devia ser recusado'; end if;
  if cid10_valido('ABC12')     then raise exception 'formato inválido devia ser recusado'; end if;
end $$;

insert into cid10 (codigo, descricao, nivel, capitulo, competencia) values
  ('I20',   'Angina pectoris',                  'categoria',    'IX',   '2008'),
  ('I20.0', 'Angina instável',                  'subcategoria', 'IX',   '2008'),
  ('I10',   'Hipertensão essencial (primária)', 'categoria',    'IX',   '2008'),
  ('M54.5', 'Dor lombar baixa',                 'subcategoria', 'XIII', '2008');

do $$
declare n int;
begin
  -- Com catálogo, só passa o que existe
  if not cid10_valido('I20.0') then raise exception 'I20.0 existe e devia passar'; end if;
  if not cid10_valido('i200')  then raise exception 'minúsculo e sem ponto devia passar'; end if;
  if cid10_valido('I20.9')     then raise exception 'I20.9 não está no catálogo e devia ser recusado'; end if;

  -- codigo_limpo é gerado pelo banco
  if (select codigo_limpo from cid10 where codigo = 'M54.5') <> 'M545' then
    raise exception 'codigo_limpo devia tirar o ponto';
  end if;

  -- Busca por código e por descrição
  select count(*) into n from buscar_cid10('I20');
  if n <> 2 then raise exception 'busca por I20 devia achar 2, achou %', n; end if;
  select count(*) into n from buscar_cid10('lombar');
  if n <> 1 then raise exception 'busca por descrição devia achar 1, achou %', n; end if;
  select count(*) into n from buscar_cid10('hipertens');
  if n <> 1 then raise exception 'busca parcial por descrição devia achar 1, achou %', n; end if;

  -- Termo curto não varre a tabela inteira
  select count(*) into n from buscar_cid10('I');
  if n <> 0 then raise exception 'termo de 1 caractere não devia buscar'; end if;

  -- O limite é respeitado e tem teto
  select count(*) into n from buscar_cid10('I', 999);
  if n <> 0 then raise exception 'termo curto continua sem buscar mesmo com limite alto'; end if;
end $$;

-- O MIRA passa a apontar CID fora do catálogo
do $$
begin
  update solicitacoes set cid10 = 'Z99.9' where id = 1;   -- formato válido, fora do catálogo
  if not exists (select 1 from mira_pendencias() where problema like '%fora do catálogo%') then
    raise exception 'mira_pendencias devia apontar CID fora do catálogo';
  end if;
  update solicitacoes set cid10 = 'I20.0' where id = 1;
  if exists (select 1 from mira_pendencias() where problema like '%fora do catálogo%') then
    raise exception 'com CID válido não devia haver pendência de catálogo';
  end if;
end $$;

-- anon não alcança o catálogo
do $$
begin
  if has_table_privilege('anon', 'public.cid10', 'SELECT') then
    raise exception 'anon não devia ler cid10';
  end if;
end $$;

select 'TESTES DA MIGRAÇÃO 005 PASSARAM' as resultado;

-- ---------------------------------------------------------------------
--  MIGRAÇÃO 007 — só uma unidade pode ser a central de regulação
-- ---------------------------------------------------------------------
do $$
declare a bigint; b bigint; n int;
begin
  insert into unidades (nome, tipo, reguladora) values ('Central A', 'solicitante', true) returning id into a;
  select count(*) into n from unidades where reguladora;
  if n <> 1 then raise exception 'devia haver exatamente uma reguladora após o primeiro insert, há %', n; end if;

  -- marcar outra desmarca a anterior, sem erro
  insert into unidades (nome, tipo, reguladora) values ('Central B', 'solicitante', true) returning id into b;
  select count(*) into n from unidades where reguladora;
  if n <> 1 then raise exception 'marcar a segunda devia deixar só uma, há %', n; end if;
  if not exists (select 1 from unidades where id = b and reguladora) then
    raise exception 'a última marcada devia ser a reguladora'; end if;
  if exists (select 1 from unidades where id = a and reguladora) then
    raise exception 'a anterior devia ter sido desmarcada'; end if;

  -- desmarcar a única não marca nenhuma outra no lugar
  update unidades set reguladora = false where id = b;
  select count(*) into n from unidades where reguladora;
  if n <> 0 then raise exception 'desmarcar devia deixar nenhuma, há %', n; end if;

  delete from unidades where id in (a, b);
end $$;

select 'TESTES DA MIGRAÇÃO 007 PASSARAM' as resultado;
