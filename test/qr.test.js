/* Testes do gerador de QR Code.
 *
 * DE ONDE VÊM ESTES HASHES, e por que isto é mais que um snapshot:
 * cada uma das 25 matrizes abaixo foi gerada por js/qr.js e depois
 * DECODIFICADA pelo leitor de QR do OpenCV, implementação independente.
 * As 25 voltaram com exatamente o texto de origem. Só então os hashes
 * foram congelados aqui.
 *
 * Então o que este arquivo garante é: o encoder continua produzindo a
 * mesma saída que um leitor real decodificou corretamente. Para
 * reverificar com o OpenCV depois de mexer no módulo, rode
 * ferramentas/verificar-qr-opencv.py.
 *
 * Os casos cobrem as versões 1 a 10 nos níveis L e M, cada uma com o
 * maior payload que cabe — pior caso para preenchimento e correção de
 * erro —, mais URLs reais, protocolo puro, acentuação em UTF-8 e um
 * único byte.
 */
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { gerarQR, qrSVG } from '../js/qr.js';

const impressao = r => createHash('sha256')
  .update(r.modulos.map(l => l.map(b => b ? 1 : 0).join('')).join(''))
  .digest('hex').slice(0, 32);

const CASOS = [
  { nivel: 'L', repete: 17, versao: 1, tamanho: 21, sha256: '04c39bc7d784e722fb203adf29844eb6' },
  { nivel: 'L', repete: 32, versao: 2, tamanho: 25, sha256: '9be9c85ec71a2f316295d64d21fb4632' },
  { nivel: 'L', repete: 53, versao: 3, tamanho: 29, sha256: '513db803f65b9b6a7228940b2eed69ad' },
  { nivel: 'L', repete: 78, versao: 4, tamanho: 33, sha256: '2691e2b8fdd327b6668ffe2b90b0d969' },
  { nivel: 'L', repete: 106, versao: 5, tamanho: 37, sha256: '46d6b0c009ef8a29a4cd96ff053ca29d' },
  { nivel: 'L', repete: 134, versao: 6, tamanho: 41, sha256: 'dba273d5c6d158633f3f76444fc1228f' },
  { nivel: 'L', repete: 154, versao: 7, tamanho: 45, sha256: 'a79de66d77bab9ab6a580ff219628cbe' },
  { nivel: 'L', repete: 192, versao: 8, tamanho: 49, sha256: 'd1cb168cda325b212538af63830b08a5' },
  { nivel: 'L', repete: 230, versao: 9, tamanho: 53, sha256: 'fe950ee1de8a2684c0bfad7a32bd7585' },
  { nivel: 'L', repete: 271, versao: 10, tamanho: 57, sha256: '37f05bec786187ccbb499f15fc13820a' },
  { nivel: 'M', repete: 14, versao: 1, tamanho: 21, sha256: '418f9a4333bbc219cafb50013459d1cc' },
  { nivel: 'M', repete: 26, versao: 2, tamanho: 25, sha256: '87aa64a73a3fa2e47393a582d8dd2d1f' },
  { nivel: 'M', repete: 42, versao: 3, tamanho: 29, sha256: '1ed740c2d0e24c8e69d1e5530f099bc8' },
  { nivel: 'M', repete: 62, versao: 4, tamanho: 33, sha256: '3f87b681aacf98f99a510cf11a551d87' },
  { nivel: 'M', repete: 84, versao: 5, tamanho: 37, sha256: '44dafe91138dd86510e237961f055df0' },
  { nivel: 'M', repete: 106, versao: 6, tamanho: 41, sha256: 'dda007f91d4c4421bc3a01a6ace292da' },
  { nivel: 'M', repete: 122, versao: 7, tamanho: 45, sha256: '3802d4c5fce3ef07204e44dd0b613b29' },
  { nivel: 'M', repete: 152, versao: 8, tamanho: 49, sha256: '95bd367f68e057a62ace8257bd793d49' },
  { nivel: 'M', repete: 180, versao: 9, tamanho: 53, sha256: '7fcc18151d17dff31a635078253e0b10' },
  { nivel: 'M', repete: 213, versao: 10, tamanho: 57, sha256: 'd277e53b6203930e860c6afe3b8da46e' },
  { nivel: 'M', texto: "https://saude.posse.go.gov.br/#/acompanhar?p=2026000001", versao: 4, tamanho: 33, sha256: 'aedd5033b10f8b417b18d27df249ffce' },
  { nivel: 'M', texto: "2026000001", versao: 1, tamanho: 21, sha256: '06d2b45e8add7364bc4409f0a7cf4600' },
  { nivel: 'M', texto: "Acentuação: ação, José, coração — çÇãõ", versao: 4, tamanho: 33, sha256: '38b34a960b52491dfbc5453c5da5fec6' },
  { nivel: 'M', texto: "https://exemplo.invalid/regula/#/acompanhar?p=2026999999&v=2", versao: 4, tamanho: 33, sha256: '7e34b05247b5be6d3fb852599b36a3f6' },
  { nivel: 'L', texto: "a", versao: 1, tamanho: 21, sha256: '2a29499fa66525efa91ff624204b3214' },
];

test('as 25 matrizes verificadas com o OpenCV continuam idênticas', () => {
  assert.equal(CASOS.length, 25);
  for(const c of CASOS){
    const texto = c.texto ?? 'A'.repeat(c.repete);
    const r = gerarQR(texto, c.nivel);
    assert.equal(r.nivel, c.nivel);
    assert.equal(r.versao, c.versao, `versão de ${JSON.stringify(texto).slice(0, 24)} em ${c.nivel}`);
    assert.equal(r.tamanho, c.tamanho);
    assert.equal(impressao(r), c.sha256,
      `a matriz mudou para ${c.texto ? JSON.stringify(c.texto) : c.repete + ' bytes'} em ${c.nivel}`);
  }
});

test('escolhe a menor versão que cabe, em cada nível', () => {
  // fronteiras exatas: o último byte que cabe e o primeiro que não cabe
  assert.equal(gerarQR('A'.repeat(17), 'L').versao, 1);
  assert.equal(gerarQR('A'.repeat(18), 'L').versao, 2);
  assert.equal(gerarQR('A'.repeat(14), 'M').versao, 1);
  assert.equal(gerarQR('A'.repeat(15), 'M').versao, 2);
  assert.equal(gerarQR('A'.repeat(213), 'M').versao, 10);
});

test('tamanho da matriz segue 4 x versão + 17', () => {
  const cap = [17, 32, 53, 78, 106, 134, 154, 192, 230, 271];
  for(let v = 1; v <= 10; v++){
    const r = gerarQR('A'.repeat(cap[v - 1]), 'L');
    assert.equal(r.versao, v);
    assert.equal(r.tamanho, 4 * v + 17);
  }
});

test('os padrões de busca estão nos três cantos', () => {
  const { modulos: m, tamanho: n } = gerarQR('teste', 'M');
  for(const [ox, oy] of [[0, 0], [n - 7, 0], [0, n - 7]]){
    for(let d = 0; d < 7; d++){
      assert.equal(m[oy][ox + d], true, 'borda superior');
      assert.equal(m[oy + 6][ox + d], true, 'borda inferior');
      assert.equal(m[oy + d][ox], true, 'borda esquerda');
      assert.equal(m[oy + d][ox + 6], true, 'borda direita');
    }
    assert.equal(m[oy + 1][ox + 1], false, 'anel claro');
    assert.equal(m[oy + 3][ox + 3], true, 'miolo escuro');
  }
});

test('linhas de temporização alternam e o módulo escuro está no lugar', () => {
  const { modulos: m, tamanho: n } = gerarQR('teste', 'M');
  for(let i = 8; i < n - 8; i++){
    assert.equal(m[6][i], i % 2 === 0, `temporização horizontal em x=${i}`);
    assert.equal(m[i][6], i % 2 === 0, `temporização vertical em y=${i}`);
  }
  /* Este módulo é sempre escuro. Ele já foi sobrescrito por um bit de
     formato quando x e y estavam trocados em aplicarFormato, e o QR
     ficava com aparência perfeita e ilegível para qualquer leitor. */
  assert.equal(m[n - 8][8], true, 'módulo sempre escuro');
});

test('UTF-8 é contado em bytes, não em caracteres', () => {
  assert.equal(Buffer.byteLength('ãçõé'), 8);
  assert.equal(gerarQR('ãçõé', 'L').versao, 1);
  // 9 caracteres acentuados são 18 bytes e já não cabem na versão 1 em L
  assert.equal(gerarQR('ã'.repeat(9), 'L').versao, 2);
});

test('recusa texto longo demais e nível não suportado', () => {
  assert.throws(() => gerarQR('A'.repeat(272), 'L'), /longo demais/);
  assert.throws(() => gerarQR('A'.repeat(214), 'M'), /longo demais/);
  assert.throws(() => gerarQR('ok', 'Q'), /não suportado/);
  assert.throws(() => gerarQR('ok', 'H'), /não suportado/);
});

test('mesma entrada gera sempre a mesma matriz', () => {
  const url = 'https://exemplo.invalid/#/acompanhar?p=2026000001';
  assert.equal(impressao(gerarQR(url, 'M')), impressao(gerarQR(url, 'M')));
});

test('qrSVG devolve SVG com zona de silêncio e um único path', () => {
  const svg = qrSVG('https://exemplo.invalid/#/acompanhar?p=2026000001', { lado: 130, titulo: 'Acompanhar' });
  assert.match(svg, /^<svg xmlns="http:\/\/www\.w3\.org\/2000\/svg" width="130" height="130"/);
  assert.match(svg, /viewBox="0 0 41 41"/);     // versão 4 (33 módulos) + 4 de margem de cada lado
  assert.equal(svg.match(/<path/g).length, 1);
  assert.match(svg, /<rect width="41" height="41" fill="#fff"\/>/);
  assert.match(svg, /aria-label="Acompanhar"/);
  assert.match(svg, /<\/svg>$/);
});

test('o título do SVG não escapa do atributo', () => {
  const svg = qrSVG('x', { titulo: 'a"><script>alert(1)</script>' });
  assert.ok(!svg.includes('<script'), 'não deve injetar tag');
  // Olha só o conteúdo do atributo: o '"><' do fim da tag <svg> é legítimo.
  const valor = /aria-label="([^"]*)"/.exec(svg)[1];
  assert.ok(!/[<>"&]/.test(valor), `aria-label não deve ter metacaractere: ${valor}`);
});
