/* Teste de fumaça do módulo da aplicação.
 *
 * Não exercita telas: carrega js/app.js com um DOM de mentira e confirma
 * que o módulo avalia sem ReferenceError. É o que pega a falha clássica de
 * modularização — uma função que ficou de fora do import e só estoura
 * quando um usuário abre a tela que a usa, em produção.
 */
import { test } from 'node:test';
import assert from 'node:assert/strict';

test('js/app.js carrega sem identificador indefinido', async () => {
  const noop = () => {};
  const el = new Proxy({}, {
    get(_, k){
      if(k === 'style' || k === 'dataset' || k === 'classList') return new Proxy({}, { get: () => noop });
      if(k === 'querySelectorAll') return () => [];
      if(typeof k === 'string') return () => el;
      return undefined;
    },
    set: () => true,
  });

  globalThis.document = {
    addEventListener: noop, removeEventListener: noop,
    querySelector: () => el, querySelectorAll: () => [],
    createElement: () => el, body: el, documentElement: el, hidden: false, title: '',
  };
  globalThis.addEventListener = noop;
  globalThis.removeEventListener = noop;
  globalThis.window = globalThis;
  globalThis.location = { hash: '', href: 'https://exemplo.invalid/', replace: noop, reload: noop };
  globalThis.sessionStorage = { getItem: () => null, setItem: noop, removeItem: noop };
  globalThis.localStorage = globalThis.sessionStorage;
  globalThis.scrollTo = noop;
  /* Sem REGULA_CONFIG, boot() cai no caminho de erro tratado — é o que
     queremos: o módulo precisa carregar, não precisa funcionar. */
  globalThis.REGULA_CONFIG = undefined;
  globalThis.supabase = undefined;

  const mod = await import('../js/app.js');
  assert.ok(mod);
});
