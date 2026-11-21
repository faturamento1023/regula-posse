#!/usr/bin/env node
/* Confere que cada bloco de migração aparece igual em schema.sql.
 *
 * Por que: schema.sql é o estado atual do banco, aplicado uma vez em banco
 * novo; migracoes/NNN-*.sql é o delta, aplicado em banco que já está em
 * produção. Os dois precisam dizer a mesma coisa, senão um município
 * instalado hoje e outro atualizado hoje ficam com bancos diferentes —
 * e a divergência só aparece meses depois, num erro difícil de entender.
 */
import { readFileSync, readdirSync } from 'node:fs';

const schema = readFileSync('banco-de-dados/schema.sql', 'utf8');
const dir = 'banco-de-dados/migracoes';
const arquivos = readdirSync(dir).filter(f => f.endsWith('.sql')).sort();

let falhas = 0;
for(const arq of arquivos){
  const num = arq.match(/^(\d+)/)?.[1];
  if(!num){ console.error(`✗ ${arq}: nome deve começar com o número da migração, ex. 002-descricao.sql`); falhas++; continue; }
  const ini = `-- MIGRACAO-${num}-INICIO`, fim = `-- MIGRACAO-${num}-FIM`;
  const texto = readFileSync(`${dir}/${arq}`, 'utf8');

  for(const [nome, conteudo] of [[arq, texto], ['schema.sql', schema]]){
    if(!conteudo.includes(ini) || !conteudo.includes(fim)){
      console.error(`✗ ${nome}: falta o marcador ${ini} ou ${fim}`);
      falhas++;
    }
  }
  if(falhas) continue;

  const corta = t => t.split(ini)[1].split(fim)[0].trim();
  if(corta(texto) !== corta(schema)){
    console.error(`✗ ${arq}: o bloco entre os marcadores difere do de schema.sql`);
    falhas++;
  } else {
    console.log(`✓ ${arq} confere com schema.sql`);
  }
}
if(falhas){ console.error(`\n${falhas} problema(s).`); process.exit(1); }
console.log(`\n${arquivos.length} migração(ões) conferida(s).`);
