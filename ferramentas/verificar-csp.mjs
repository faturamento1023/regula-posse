#!/usr/bin/env node
/* Guarda as decisões que fazem o Content-Security-Policy valer.
 *
 * São checagens mecânicas, sem palpite: ou o arquivo tem script inline ou
 * não tem. Isso é de propósito — verificador que dá falso positivo é
 * verificador que alguém desliga no mês seguinte.
 *
 * O que ele impede de voltar sem ninguém notar:
 *   1. atributo de evento inline (onclick=, onsubmit=...), que o CSP bloqueia
 *   2. <script> com código dentro do HTML, que o CSP também bloqueia
 *   3. <script src> de origem que não está no script-src do CSP
 *   4. js/util.js tocando no DOM, o que o tornaria intestável no node
 */
import { readFileSync } from 'node:fs';

const html = readFileSync('index.html', 'utf8');
const erros = [];

/* 1. atributos de evento inline */
for(const m of html.matchAll(/\son([a-z]{3,20})\s*=\s*"/g)){
  const linha = html.slice(0, m.index).split('\n').length;
  erros.push(`index.html:${linha}: atributo on${m[1]}= inline. O CSP bloqueia handler inline — `
    + `use data-acao e registre em ACOES_DOC (js/app.js).`);
}

/* 2. <script> com conteúdo */
for(const m of html.matchAll(/<script\b([^>]*)>([\s\S]*?)<\/script>/g)){
  if(m[2].trim() === '') continue;
  const linha = html.slice(0, m.index).split('\n').length;
  erros.push(`index.html:${linha}: <script> com código dentro do HTML. O CSP bloqueia script `
    + `inline — mova para um arquivo em js/ e carregue com src.`);
}

/* 3. origem de cada <script src> precisa estar liberada no script-src */
const csp = html.match(/http-equiv="Content-Security-Policy"\s+content="([^"]+)"/)?.[1];
if(!csp){
  erros.push('index.html: falta o <meta http-equiv="Content-Security-Policy">.');
} else {
  const scriptSrc = csp.split(';').map(d => d.trim()).find(d => d.startsWith('script-src'));
  if(!scriptSrc) erros.push('index.html: o CSP não declara script-src.');
  else {
    const liberadas = scriptSrc.split(/\s+/).slice(1);
    for(const m of html.matchAll(/<script\b[^>]*\bsrc="([^"]+)"/g)){
      const src = m[1];
      if(!/^https?:\/\//.test(src)) continue;            // caminho relativo = 'self'
      const origem = new URL(src).origin;
      const ok = liberadas.some(d => d === origem
        || (d.startsWith('https://*.') && origem.endsWith(d.slice('https://*'.length))));
      if(!ok){
        const linha = html.slice(0, m.index).split('\n').length;
        erros.push(`index.html:${linha}: script de ${origem}, que não está no script-src do CSP. `
          + `Versione o arquivo (ferramentas/vendorizar-supabase.sh) ou libere a origem.`);
      }
    }
  }
}

/* 4. js/util.js precisa continuar puro */
const util = readFileSync('js/util.js', 'utf8');
for(const api of ['document', 'window', 'localStorage', 'sessionStorage', 'fetch(']){
  if(new RegExp(`\\b${api.replace('(', '\\(')}`).test(util.replace(/\/\*[\s\S]*?\*\/|\/\/.*/g, ''))){
    erros.push(`js/util.js usa ${api}. Este módulo tem de seguir puro para rodar `
      + `em test/util.test.js sem navegador — o que toca o DOM vai para js/app.js.`);
  }
}

if(erros.length){
  console.error('Verificação do CSP falhou:\n');
  for(const e of erros) console.error('  ✗ ' + e);
  process.exit(1);
}
console.log('✓ nenhum script inline, nenhum handler inline, origens conferem, js/util.js puro');
