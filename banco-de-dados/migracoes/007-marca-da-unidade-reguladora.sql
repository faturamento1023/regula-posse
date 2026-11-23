-- =====================================================================
--  MIGRAÇÃO 007 — a central de regulação como tipo de unidade
--  ---------------------------------------------------------------------
--  Para bancos já em produção: Supabase > SQL Editor > cole e execute.
--  Depende da migração 003, que cria a coluna unidades.reguladora.
--  Pode ser executado mais de uma vez.
-- =====================================================================

-- MIGRACAO-007-INICIO

-- ---------------------------------------------------------------------
--  A CENTRAL DE REGULAÇÃO É UM TIPO DE UNIDADE
--
--  "tipo" diz o que a unidade faz no fluxo, e é o que filtra as duas
--  listas do sistema: de onde o pedido sai, e onde o paciente é
--  atendido. A central não é nenhuma das duas — ela recebe o pedido da
--  unidade de origem e decide. Cadastrá-la como solicitante a fazia
--  aparecer na lista de origem do pedido, oferecendo à atendente uma
--  opção que nunca é a resposta certa.
--
--  Daí o quarto valor. E, junto, os filtros do aplicativo passaram a ser
--  listas do que entra, não do que fica de fora: escritos como negação,
--  qualquer tipo novo entraria por engano na lista de origem.
--
--  A coluna reguladora (migração 003) continua existindo porque é dela
--  que a vw_mira lê o CNES do estabelecimento regulador. Mas deixa de
--  ser preenchida à mão: passa a ser derivada do tipo, de modo que não
--  existe o estado em que a tela diz uma coisa e o lote enviado ao
--  Ministério diz outra.
-- ---------------------------------------------------------------------
alter table unidades drop constraint if exists unidades_tipo_check;
alter table unidades add constraint unidades_tipo_check
  check (tipo in ('solicitante','executante','ambos','regulacao'));

comment on column unidades.tipo is
  'Papel da unidade no fluxo: solicitante (origem do pedido), executante (local de atendimento), ambos, ou regulacao (a central, que não é origem nem local de atendimento).';

-- Bancos que aplicaram a 003 e marcaram a reguladora à mão: preserva a
-- intenção, convertendo a marca em tipo antes de a marca virar derivada.
update unidades set tipo = 'regulacao'
 where reguladora and tipo <> 'regulacao'
   and id = (select min(id) from unidades where reguladora);

-- Só uma central. A segunda é recusada, em vez de a primeira cair em
-- silêncio: trocar a central é uma decisão, não um efeito colateral.
create unique index if not exists unidades_uma_reguladora
  on unidades ((tipo)) where tipo = 'regulacao';

create or replace function sincronizar_reguladora()
returns trigger language plpgsql as $$
begin
  new.reguladora := (new.tipo = 'regulacao');
  return new;
end $$;

comment on function sincronizar_reguladora() is
  'Mantém unidades.reguladora derivada de unidades.tipo, para que a marca lida pelo MIRA não possa divergir do que a tela mostra.';

drop trigger if exists unica_reguladora on unidades;          -- versão anterior desta migração
drop function if exists marcar_unica_reguladora();
drop trigger if exists reguladora_do_tipo on unidades;
create trigger reguladora_do_tipo
  before insert or update on unidades
  for each row execute function sincronizar_reguladora();

update unidades set reguladora = (tipo = 'regulacao')
 where reguladora is distinct from (tipo = 'regulacao');

-- MIGRACAO-007-FIM
