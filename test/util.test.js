import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  h, raw, html, dig, safeLike, pct, num,
  hojeISO, addDias, fmtData, fmtHora, brParaISO, idade, diaSemana, inicioMes,
  MASK, fCPF, fCNS, cpfOculto, cnsOculto,
  validaCPF, validaCNS,
} from '../js/util.js';

/* ------------------------------------------------------------------ */
test('h escapa os cinco caracteres perigosos', () => {
  assert.equal(h(`<a href="x">&'`), '&lt;a href=&quot;x&quot;&gt;&amp;&#39;');
  assert.equal(h(null), '');
  assert.equal(h(undefined), '');
  assert.equal(h(0), '0');
});

test('html escapa interpolação por padrão', () => {
  const nome = '<script>alert(1)</script>';
  assert.equal(html`<b>${nome}</b>`, '<b>&lt;script&gt;alert(1)&lt;/script&gt;</b>');
});

test('html preserva o que foi marcado com raw', () => {
  assert.equal(html`<td>${raw('<span>ok</span>')}</td>`, '<td><span>ok</span></td>');
});

test('html concatena array e ignora null e false', () => {
  assert.equal(html`${['a', 'b']}`, 'ab');
  assert.equal(html`x${null}y${false}z${undefined}`, 'xyz');
});

test('html escapa os itens de um array', () => {
  assert.equal(html`${['<i>', '&']}`, '&lt;i&gt;&amp;');
});

/* ------------------------------------------------------------------ */
test('dig mantém só dígitos', () => {
  assert.equal(dig('123.456.789-09'), '12345678909');
  assert.equal(dig(null), '');
});

test('safeLike remove o que quebra o filtro do PostgREST', () => {
  assert.equal(safeLike('maria (silva), 50%'), 'maria  silva   50');
  assert.equal(safeLike('  joão  '), 'joão');
});

test('pct e num formatam no padrão brasileiro', () => {
  assert.equal(pct(1, 3), '33,3%');
  assert.equal(pct(5, 0), '—');
  assert.equal(num(1234567), '1.234.567');
});

/* ------------------------------------------------------------------ */
test('hojeISO devolve AAAA-MM-DD', () => {
  assert.match(hojeISO(), /^\d{4}-\d{2}-\d{2}$/);
});

test('addDias atravessa virada de mês e de ano', () => {
  assert.equal(addDias('2026-01-31', 1), '2026-02-01');
  assert.equal(addDias('2026-12-31', 1), '2027-01-01');
  assert.equal(addDias('2026-03-01', -1), '2026-02-28');
  assert.equal(addDias('2024-02-28', 1), '2024-02-29');   // ano bissexto
});

test('addDias não escorrega um dia na virada do horário de verão', () => {
  // Cobre a razão do 'T12:00': à meia-noite um deslocamento de -1h
  // jogaria o resultado para o dia anterior.
  assert.equal(addDias('2026-10-17', 1), '2026-10-18');
  assert.equal(addDias('2026-02-14', 1), '2026-02-15');
});

test('fmtData e fmtHora', () => {
  assert.equal(fmtData('2026-11-20'), '20/11/2026');
  assert.equal(fmtData('2026-11-20T15:30:00Z'), '20/11/2026');
  assert.equal(fmtData(null), '—');
  assert.equal(fmtHora('15:30:00'), '15:30');
  assert.equal(fmtHora(null), '');
});

test('brParaISO aceita data válida e rejeita data inexistente', () => {
  assert.equal(brParaISO('20/11/2026'), '2026-11-20');
  assert.equal(brParaISO('29/02/2024'), '2024-02-29');
  assert.equal(brParaISO('31/02/2026'), null);
  assert.equal(brParaISO('30/02/2026'), null);
  assert.equal(brParaISO('20/13/2026'), null);
  assert.equal(brParaISO('2026-11-20'), null);
  assert.equal(brParaISO(''), null);
});

test('idade não conta o aniversário que ainda não chegou', () => {
  const hj = new Date();
  const iso = d => new Intl.DateTimeFormat('sv-SE').format(d);
  const fezAnosOntem = new Date(hj.getFullYear() - 30, hj.getMonth(), hj.getDate() - 1);
  const fazAnosAmanha = new Date(hj.getFullYear() - 30, hj.getMonth(), hj.getDate() + 1);
  assert.equal(idade(iso(fezAnosOntem)), 30);
  assert.equal(idade(iso(fazAnosAmanha)), 29);
  assert.equal(idade(''), '');
});

test('diaSemana e inicioMes', () => {
  assert.equal(diaSemana('2026-11-20'), 'Sex');
  assert.equal(diaSemana('2026-11-20', true), 'Sexta-feira');
  assert.match(inicioMes(), /^\d{4}-\d{2}-01$/);
});

/* ------------------------------------------------------------------ */
test('máscaras formatam progressivamente', () => {
  assert.equal(MASK.cpf('12345678909'), '123.456.789-09');
  assert.equal(MASK.cpf('123456'), '123.456');
  assert.equal(MASK.cns('100000107160494'), '100 0001 0716 0494');
  assert.equal(MASK.tel('62999887766'), '(62) 99988-7766');
  assert.equal(MASK.tel('6233334444'), '(62) 3333-4444');
  assert.equal(MASK.cep('73900000'), '73900-000');
  assert.equal(MASK.data('20112026'), '20/11/2026');
  assert.equal(MASK.guia('26000015'), '26000015');
});

test('máscaras descartam excesso de dígitos', () => {
  assert.equal(MASK.cpf('1234567890999999'), '123.456.789-09');
  assert.equal(MASK.guia('123456789012345'), '1234567890');
});

test('formatadores devolvem travessão quando vazio', () => {
  assert.equal(fCPF(''), '—');
  assert.equal(fCNS(null), '—');
});

test('cpfOculto e cnsOculto escondem o começo', () => {
  assert.equal(cpfOculto('12345678909'), '***.456.789-**');
  assert.equal(cpfOculto('123'), '—');
  assert.equal(cnsOculto('100000107160494'), '*** **** **** 0494');
  assert.equal(cnsOculto(''), '—');
});

/* ------------------------------------------------------------------ */
test('validaCPF aceita CPF válido, com ou sem máscara', () => {
  for(const c of ['01111111103', '01234567890', '01358024588']){
    assert.equal(validaCPF(c), true, c);
  }
  assert.equal(validaCPF('012.345.678-90'), true);
});

test('validaCPF rejeita dígito verificador errado', () => {
  assert.equal(validaCPF('01234567891'), false);
  assert.equal(validaCPF('01234567800'), false);
});

test('validaCPF rejeita repetição, tamanho errado e vazio', () => {
  for(const c of ['11111111111', '00000000000', '99999999999']){
    assert.equal(validaCPF(c), false, c);
  }
  assert.equal(validaCPF('0123456789'), false);
  assert.equal(validaCPF('012345678901'), false);
  assert.equal(validaCPF(''), false);
  assert.equal(validaCPF(null), false);
});

test('validaCNS aceita CNS válido das séries 1 e 7', () => {
  assert.equal(validaCNS('100000107160494'), true);
  assert.equal(validaCNS('100 0001 0716 0494'), true);
  assert.equal(validaCNS('700000000000005'), true);
});

test('validaCNS rejeita primeiro dígito fora das séries válidas', () => {
  assert.equal(validaCNS('300000107160494'), false);
  assert.equal(validaCNS('000000107160494'), false);
});

test('validaCNS rejeita soma ponderada errada e tamanho errado', () => {
  assert.equal(validaCNS('100000107160495'), false);
  assert.equal(validaCNS('10000010716049'), false);
  assert.equal(validaCNS(''), false);
});
