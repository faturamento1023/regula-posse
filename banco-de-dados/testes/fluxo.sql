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
