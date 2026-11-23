-- =====================================================================
--  MIGRAÇÃO 007 — marca da unidade reguladora
--  ---------------------------------------------------------------------
--  Para bancos já em produção: Supabase > SQL Editor > cole e execute.
--  Depende da migração 003, que cria a coluna unidades.reguladora.
--  Pode ser executado mais de uma vez.
-- =====================================================================

-- MIGRACAO-007-INICIO

-- ---------------------------------------------------------------------
--  A CENTRAL DE REGULAÇÃO NÃO É UM TIPO DE UNIDADE
--
--  "Solicitante" e "local de atendimento" dizem o que a unidade faz no
--  fluxo: de onde o pedido sai e onde o paciente é atendido. Ser a
--  central de regulação é outra coisa — é uma atribuição do município,
--  e ela pode acumular com as duas. Por isso a marca é um campo próprio
--  (unidades.reguladora, criado na migração 003) e não um quarto valor
--  de "tipo": como quarto valor, ela excluiria as combinações possíveis
--  e mudaria em silêncio o que aparece nas listas de origem do pedido e
--  de local de atendimento, que são filtradas por tipo.
--
--  O que falta é a garantia de que exista no máximo uma: o CNES da
--  reguladora vai no elemento "estabelecimento regulador" de todo lote
--  enviado ao Ministério, e duas marcadas tornariam esse elemento
--  indefinido — o lote sairia com o CNES de uma ou de outra conforme a
--  ordem de leitura, sem ninguém perceber.
--
--  Em vez de recusar a segunda marcação com erro, a marca anterior cai.
--  É o comportamento que o município espera quando a central muda de
--  endereço ou de CNES: marca a nova, e a antiga deixa de ser.
-- ---------------------------------------------------------------------
create or replace function marcar_unica_reguladora()
returns trigger language plpgsql as $$
begin
  update unidades
     set reguladora = false
   where reguladora
     and id is distinct from new.id;
  return null;
end $$;

comment on function marcar_unica_reguladora() is
  'Mantém no máximo uma unidade marcada como central de regulação: marcar uma desmarca a anterior.';

drop trigger if exists unica_reguladora on unidades;
create trigger unica_reguladora
  after insert or update of reguladora on unidades
  for each row when (new.reguladora)
  execute function marcar_unica_reguladora();

-- MIGRACAO-007-FIM
