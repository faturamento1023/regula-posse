/* =====================================================================
   REGULA POSSE — aplicação
   ---------------------------------------------------------------------
   Arquivo externo de propósito: o Content-Security-Policy declarado em
   index.html proíbe script inline, então nada de código dentro do HTML.
   As funções puras ficam em js/util.js, com testes em test/.
   ===================================================================== */
/* As funções puras — escape de HTML, datas, máscaras e validações — ficam
   em js/util.js e são cobertas por test/util.test.js (node --test).
   Observação: 'html' aqui é o template literal que escapa por padrão;
   algumas funções antigas têm um parâmetro com esse mesmo nome, que as
   sombreia localmente. Ao migrar cada uma, renomeie o parâmetro para
   'conteudo' para poder usar o template dentro dela. */
import {
  h, raw, html, dig, opts, debounce, safeLike, pct, num, uid,
  DIAS, DIAS_LONGO, hojeISO, addDias, fmtData, fmtDataHora, fmtHora,
  diaSemana, dataExtenso, idade, brParaISO, inicioMes,
  MASK, fCPF, fCNS, fTel, fCEP, cpfOculto, cnsOculto,
  validaCNS, validaCPF,
} from './util.js';
import { qrSVG } from './qr.js';
/* =====================================================================
   CONFIGURAÇÃO LOCAL
   ===================================================================== */
const ORGAO     = 'Secretaria Municipal de Saúde de Posse';  // cabeçalho da guia e dos relatórios
const MUNICIPIO = { cidade:'Posse', uf:'GO' };               // padrão do endereço do paciente

/* Critérios de classificação de risco do PROTOCOLO LOCAL.
   Ficam vazios de propósito: o sistema não cria critério clínico.
   Quando a regulação municipal aprovar um protocolo, preencha aqui
   (um texto por item) e eles aparecem como orientação nas telas. */
const CRITERIOS_RISCO = { vermelho:[], amarelo:[], verde:[], azul:[] };

/* ===================================================================== */
const store = {
  get(k){ try { return JSON.parse(sessionStorage.getItem(k)); } catch { return null; } },
  set(k,v){ try { sessionStorage.setItem(k, JSON.stringify(v)); } catch {} },
  del(k){ try { sessionStorage.removeItem(k); } catch {} }
};

let sb = null;
const S = { user:null, perfil:null, unidades:[], procedimentos:[], unProc:[], profs:[] };

const PRIORIDADES = {
  vermelho:{ l:'Vermelho', d:'Emergência', c:'var(--p-vermelho)', s:'◆' },
  amarelo: { l:'Amarelo',  d:'Urgente',    c:'var(--p-amarelo)',  s:'▲' },
  verde:   { l:'Verde',    d:'Prioritário',c:'var(--p-verde)',    s:'●' },
  azul:    { l:'Azul',     d:'Eletivo',    c:'var(--p-azul)',     s:'■' }
};
const STATUS = {
  pendente:'Aguardando agendamento', regulacao:'Aguardando regulação', autorizada:'Autorizada — aguardando vaga',
  devolvida:'Devolvida à unidade', negada:'Negada', agendada:'Agendada', realizada:'Realizada', faltou:'Falta', cancelada:'Cancelada'
};
const STATUS_ICO = { pendente:'◷', regulacao:'⚖', autorizada:'✓', devolvida:'↩', negada:'✕', agendada:'▸', realizada:'✓', faltou:'✕', cancelada:'⊘',
  livre:'○', ocupada:'●', bloqueada:'⊘', ativo:'✓', inativo:'⊘' };
const PAPEIS = { admin:'Administrador', solicitante:'Atendente', agendador:'Agendador / Central', regulador:'Regulador', executante:'Local de atendimento' };
const TIPOS_PROC = { consulta:'Consulta', exame:'Exame', cirurgia:'Cirurgia', terapia:'Terapia', outro:'Outro' };
const TIPOS_UNI = { solicitante:'Solicitante (UBS / origem)', executante:'Local de atendimento', ambos:'Solicitante e local de atendimento' };
const UFS = 'AC AL AP AM BA CE DF ES GO MA MT MS MG PA PB PR PE PI RJ RN RS RO RR SC SP SE TO'.split(' ');
const AGUARDANDO = ['pendente','autorizada'];
const ABERTAS = ['pendente','autorizada','agendada','devolvida'];
const ICONES = {
  inicio:'assets/icons/inicio.png', solicitacao:'assets/icons/solicitacao.png', agendamento:'assets/icons/agendamento.png',
  confirmacao:'assets/icons/confirmacao.png', agendas:'assets/icons/agendas.png', relatorios:'assets/icons/relatorios.png',
  pacientes:'assets/icons/pacientes.png', usuarios:'assets/icons/usuarios.png',
  regulacao:'assets/icons/regulacao.svg', fila:'assets/icons/fila.svg', locais:'assets/icons/locais.svg', procedimentos:'assets/icons/procedimentos.svg'
};

/* ---------------- utilitários do DOM ---------------- */
/* O resto dos utilitários está em js/util.js. */
const $ = (s, r=document) => r.querySelector(s);
const $$ = (s, r=document) => [...r.querySelectorAll(s)];

/* aplica a máscara declarada em data-mask enquanto o usuário digita */
document.addEventListener('input', e => {
  const m = e.target.dataset && e.target.dataset.mask;
  if(m && MASK[m]){ e.target.value = MASK[m](e.target.value); }
});

/* Delegação de eventos. Os handlers que antes eram atributos onclick no
   HTML viraram data-acao, para que o Content-Security-Policy possa proibir
   script inline. Um listener só, no documento, sobrevive a qualquer
   redesenho de tela — não há handler para religar depois do innerHTML. */
const ACOES_DOC = {
  'fechar-alerta': b => b.closest('.alert')?.remove(),
  'alternar-filtros': b => {
    const f = b.closest('form'); if(!f) return;
    const aberto = f.classList.toggle('aberto');
    b.setAttribute('aria-expanded', String(aberto));
    b.textContent = aberto ? 'Menos filtros' : 'Mais filtros';
  },
};
document.addEventListener('click', e => {
  const b = e.target.closest && e.target.closest('[data-acao]');
  if(b) ACOES_DOC[b.dataset.acao]?.(b, e);
});
/* formulários de filtro: filtram ao digitar, nunca submetem */
document.addEventListener('submit', e => {
  if(e.target.hasAttribute && e.target.hasAttribute('data-sem-submit')) e.preventDefault();
});

/* =====================================================================
   LOG DE ERRO
   Sem isto, "deu erro aqui" é irreproduzível: não há console aberto na
   recepção da unidade. Gravamos o mínimo para diagnóstico. Sequências de
   6 dígitos ou mais são mascaradas porque mensagem de erro do Postgres
   pode trazer o valor que violou a restrição — um CPF, um Cartão SUS.
   Falha ao gravar o log é ignorada de propósito: o log não pode virar a
   causa de um segundo erro.
   ===================================================================== */
const semIdentificadores = t => String(t ?? '').replace(/\d{6,}/g, '[número]');
function registrarErro(e, onde){
  console.error(onde || '', e);
  try {
    if(!sb || !S.user) return;
    sb.rpc('registrar_erro', {
      p_onde:     String(onde ?? '').slice(0, 120),
      p_mensagem: semIdentificadores(e?.message ?? e).slice(0, 500),
      p_pilha:    semIdentificadores(e?.stack).slice(0, 2000),
      p_rota:     String(location.hash).slice(0, 200),
      p_agente:   String(navigator.userAgent).slice(0, 300),
    }).then(() => {}, () => {});
  } catch { /* nunca propaga */ }
}
/* Registro de acesso a cadastro de paciente, para a auditoria da LGPD.
   Dispara e segue: se falhar, não pode atrapalhar quem está atendendo.
   A deduplicação por janela é feita no banco, então chamar de novo na
   mesma tela não polui o log. Cobre abertura deliberada de cadastro, não
   toda consulta — ver a nota na migração 003. */
function registrarAcesso(pacienteId, contexto){
  if(!sb || !S.user || !pacienteId) return;
  try {
    sb.rpc('registrar_acesso_paciente', { p_paciente_id: pacienteId, p_contexto: contexto })
      .then(() => {}, e => registrarErro(e, 'registrarAcesso'));
  } catch(e){ registrarErro(e, 'registrarAcesso'); }
}

window.addEventListener('error', e => registrarErro(e.error ?? e.message, 'window.onerror'));
window.addEventListener('unhandledrejection', e => registrarErro(e.reason, 'promessa não tratada'));

/* ---------------- etiquetas ---------------- */
const badgePrio = (p, longo) => p ? `<span class="badge pr-${p}"><span class="s" aria-hidden="true">${PRIORIDADES[p].s}</span>${h(PRIORIDADES[p].l)}${longo ? ' — ' + h(PRIORIDADES[p].d) : ''}</span>` : '';
function chaveStatus(x){
  if(typeof x === 'string') return x;
  return x.status === 'pendente' && x.exige_regulacao ? 'regulacao' : x.status;
}
const rotuloStatus = x => STATUS[chaveStatus(x)] || chaveStatus(x);
const badgeSt = x => { const k = chaveStatus(x); const cls = k === 'regulacao' ? 'st-regulacao' : 'st-' + k;
  const rot = STATUS[k] || ({ livre:'Livre', ocupada:'Ocupada', bloqueada:'Bloqueada', ativo:'Ativo', inativo:'Inativo' }[k] || k);
  return `<span class="badge ${cls}"><span class="s" aria-hidden="true">${STATUS_ICO[k] || ''}</span>${h(rot)}</span>`; };
/* As duas esperas. dias_espera conta do lançamento no sistema e é o que
   ordena a fila; dias_desde_pedido conta do pedido médico, que é a espera
   real do paciente. A diferença é tempo que o paciente esperou e a fila não
   conta — mostrar isso lado a lado é o que permite medir o problema. */
function esperaDupla(s){
  if(s.dias_desde_pedido == null) return '';
  const atraso = s.dias_ate_insercao;
  const alto = atraso != null && atraso >= 7;
  return `<p class="muted" style="margin:0 0 10px;font-size:13px">
    Espera desde o pedido médico (${fmtData(s.data_pedido)}): <b>${num(s.dias_desde_pedido)} dia(s)</b>
    · na fila, contada do lançamento: <b>${num(s.dias_espera)} dia(s)</b>
    ${atraso ? `· <span class="${alto ? 'tag inc' : ''}">levou ${num(atraso)} dia(s) para ser lançada</span>` : ''}</p>`;
}
const tagReg = () => `<span class="tag" title="Este procedimento passa pela análise regulatória antes do agendamento">Exige regulação</span>`;
const nomeUnidade = id => S.unidades.find(u => u.id === id)?.nome || '—';
const nomeProc = id => S.procedimentos.find(p => p.id === id)?.nome || '—';
const procExige = id => !!S.procedimentos.find(p => p.id === id)?.exige_regulacao;
const papel = () => S.perfil?.papel;
const can = (...p) => p.includes(papel());
const locaisExec = () => S.unidades.filter(u => u.ativo && u.tipo !== 'solicitante');
const locaisDoProc = pid => { const ids = S.unProc.filter(x => x.procedimento_id === pid).map(x => x.unidade_id);
  const l = locaisExec().filter(u => ids.includes(u.id)); return l.length ? l : locaisExec(); };
const procsDoLocal = uid => { const ids = S.unProc.filter(x => x.unidade_id === uid).map(x => x.procedimento_id);
  return S.procedimentos.filter(p => ids.includes(p.id)); };
const optList = (lista, sel, vazio) => (vazio != null ? `<option value="">${h(vazio)}</option>` : '') +
  lista.map(o => `<option value="${h(o.id)}" ${String(o.id)===String(sel)?'selected':''}>${h(o.nome)}${o.ativo===false?' (inativo)':''}</option>`).join('');
const params = () => new URLSearchParams(location.hash.split('?')[1] || '');
const img = (k, alt='') => `<img src="${ICONES[k]}" alt="${h(alt)}" width="28" height="28">`;

/* Pendências de preenchimento que atrapalham a análise (só informativo) */
function pendencias(s){
  const p = [];
  if(!s.justificativa) p.push('sem justificativa clínica');
  if(!s.cid10) p.push('sem CID-10');
  if(!s.profissional_solicitante) p.push('sem profissional solicitante');
  if(!s.crm_solicitante) p.push('sem CRM');
  if(!s.paciente_telefone) p.push('paciente sem telefone');
  if(!s.paciente_cns && !s.paciente_cpf) p.push('paciente sem CPF/CNS');
  return p;
}
const tagIncompleto = s => { const p = pendencias(s); return p.length ? `<span class="tag inc" title="${h(p.join(', '))}">Incompleto: ${p.length}</span>` : ''; };

/* ---------------- acesso a dados ---------------- */
async function q(promise){
  const { data, error } = await promise;
  if(error) throw new Error(traduzErro(error.message));
  return data;
}
async function fetchAll(make, max=60000){
  const out = [];
  for(let from=0; from<max; from+=1000){
    const d = await q(make().range(from, from+999));
    out.push(...d); if(d.length < 1000) break;
  }
  return out;
}
function traduzErro(m=''){
  if(/duplicate key.*cns/i.test(m)) return 'Já existe paciente com este Cartão SUS.';
  if(/duplicate key.*cpf/i.test(m)) return 'Já existe paciente com este CPF.';
  if(/duplicate key.*cnes/i.test(m)) return 'Já existe unidade com este CNES.';
  if(/row-level security/i.test(m)) return 'Seu perfil não tem permissão para esta ação.';
  if(/violates foreign key/i.test(m)) return 'Este registro está em uso e não pode ser excluído. Desative-o em vez de excluir.';
  return m;
}

/* ---------------- avisos ---------------- */
function toast(msg, type=''){
  const t = document.createElement('div'); t.className = 'toast '+type;
  t.innerHTML = `<span>${h(msg)}</span><button aria-label="Fechar aviso">×</button>`;
  $('button', t).onclick = () => t.remove();
  $('#toasts').appendChild(t); setTimeout(() => t.remove(), type==='err' ? 9000 : 5000);
}
/* aviso que permanece na tela até o usuário trocar de tela ou fechar */
function aviso(html, tipo='ok', titulo=''){
  const ic = { ok:'✓', err:'⚠', warn:'!', info:'i' }[tipo];
  $('#aviso-global').innerHTML = `<div class="alert ${tipo}" role="${tipo==='err'?'alert':'status'}"><span class="ai" aria-hidden="true">${ic}</span>
    <div>${titulo ? `<b class="t">${h(titulo)}</b>` : ''}${html}</div><button class="btn sm link" aria-label="Fechar aviso" data-acao="fechar-alerta">Fechar</button></div>`;
}
const alerta = (tipo, html, titulo='') => `<div class="alert ${tipo}" ${tipo==='err'?'role="alert"':''}><span class="ai" aria-hidden="true">${{ ok:'✓', err:'⚠', warn:'!', info:'i' }[tipo]}</span><div>${titulo?`<b class="t">${h(titulo)}</b>`:''}${html}</div></div>`;

const carregando = (txt='Carregando…', inline=false) =>
  `<div class="carregando ${inline?'inline':''}" role="status"><img src="assets/loading/carregando-cruz.gif" alt="" width="48" height="48"><span>${h(txt)}</span></div>`;

/* estados: vazio | erro | permissao | sucesso */
function estado({ tipo='vazio', titulo, texto='', acoes=[] }){
  const ico = { vazio:ICONES.fila, erro:null, permissao:null, sucesso:ICONES.confirmacao }[tipo];
  const simb = { erro:'⚠', permissao:'⊘' }[tipo];
  return `<div class="estado" ${tipo==='erro'?'role="alert"':''}>
    ${ico ? `<img src="${ico}" alt="">` : `<div style="font-size:40px;line-height:1;margin-bottom:8px" aria-hidden="true">${simb}</div>`}
    <h3>${h(titulo)}</h3>${texto ? `<p>${texto}</p>` : ''}
    ${acoes.length ? `<div class="acoes">${acoes.map(a => a.href ? `<a class="btn ${a.cls||''}" href="${a.href}">${h(a.label)}</a>` : `<button class="btn ${a.cls||''}" data-estado-acao="${h(a.id)}">${h(a.label)}</button>`).join('')}</div>` : ''}
  </div>`;
}

/* executa uma ação mostrando "ocupado" no botão */
async function ocupado(btn, fn){
  if(btn){ btn.disabled = true; btn.setAttribute('aria-busy','true'); }
  try { return await fn(); }
  finally { if(btn && btn.isConnected){ btn.disabled = false; btn.removeAttribute('aria-busy'); } }
}

/* ---------------- janela (modal) acessível ---------------- */
function modal({ title, body, actions=[], wide=false, estreito=false, onOpen, onClose }){
  const anterior = document.activeElement;
  const tid = uid('mt');
  const bg = document.createElement('div'); bg.className = 'modal-bg';
  bg.innerHTML = `<div class="modal ${wide?'wide':''} ${estreito?'estreito':''}" role="dialog" aria-modal="true" aria-labelledby="${tid}">
    <header><h2 id="${tid}">${h(title)}</h2><button class="x" data-close aria-label="Fechar janela">&times;</button></header>
    <div class="modal-body">${body}</div><footer></footer></div>`;
  const close = () => { bg.remove(); document.removeEventListener('keydown', tecla, true); onClose && onClose(); if(anterior && anterior.isConnected) anterior.focus(); };
  bg.close = close;
  const foot = $('footer', bg);
  actions.forEach(a => {
    const b = document.createElement('button');
    b.className = 'btn ' + (a.cls || ''); b.textContent = a.label; b.type = 'button';
    b.onclick = async () => {
      if(!a.onClick){ close(); return; }
      $$('button', foot).forEach(x => x.disabled = true); b.setAttribute('aria-busy','true');
      try { const r = await a.onClick(bg); if(r !== false) close(); }
      catch(e){ if(!(e instanceof ErroForm)) toast(e.message, 'err'); }
      finally { $$('button', foot).forEach(x => x.disabled = false); b.removeAttribute('aria-busy'); }
    };
    foot.appendChild(b);
  });
  const tecla = e => {
    if(!bg.isConnected) return;
    if(e.key === 'Escape' && document.querySelectorAll('.modal-bg').length && [...document.querySelectorAll('.modal-bg')].pop() === bg){ e.preventDefault(); close(); }
    if(e.key === 'Tab'){
      const f = $$('a[href],button:not([disabled]),input:not([disabled]),select:not([disabled]),textarea:not([disabled]),[tabindex]:not([tabindex="-1"])', bg).filter(x => x.offsetParent !== null);
      if(!f.length) return;
      if(e.shiftKey && document.activeElement === f[0]){ e.preventDefault(); f[f.length-1].focus(); }
      else if(!e.shiftKey && document.activeElement === f[f.length-1]){ e.preventDefault(); f[0].focus(); }
    }
  };
  document.addEventListener('keydown', tecla, true);
  $('[data-close]', bg).onclick = close;
  document.body.appendChild(bg);
  if(onOpen) Promise.resolve(onOpen(bg)).catch(e => toast(e.message, 'err'));
  const first = $('.modal-body input:not([type=hidden]):not([type=checkbox]):not([type=radio]),.modal-body select,.modal-body textarea', bg) || $('footer button:last-child', bg) || $('[data-close]', bg);
  if(first) first.focus();
  return bg;
}

/* Confirmação com resumo e, se preciso, campo de texto obrigatório.
   Retorna Promise<{ ok, texto }> */
function confirmar({ titulo, html='', botao='Confirmar', cls='pri', campo=null }){
  return new Promise(resolve => {
    let res = { ok:false };
    const cid = uid('cf');
    modal({ title:titulo, estreito:!campo, onClose: () => resolve(res),
      body: html + (campo ? `<div class="field ${campo.obrigatorio?'':''}" style="margin-top:12px">
          <label for="${cid}">${h(campo.label)}${campo.obrigatorio ? '' : ' <span class="opc">(opcional)</span>'}</label>
          ${campo.dica ? `<span class="dica" id="${cid}-d">${h(campo.dica)}</span>` : ''}
          <p class="erro-msg hidden" id="${cid}-e"></p>
          <textarea id="${cid}" rows="3" ${campo.dica?`aria-describedby="${cid}-d"`:''}>${h(campo.valor||'')}</textarea></div>` : ''),
      actions:[{ label:'Voltar' }, { label:botao, cls, onClick: m => {
        if(campo){
          const t = $('#'+cid, m).value.trim();
          if(campo.obrigatorio && t.length < (campo.min || 1)){
            const e = $('#'+cid+'-e', m); e.textContent = campo.msg || `Preencha o campo "${campo.label}".`; e.classList.remove('hidden');
            $('#'+cid, m).setAttribute('aria-invalid','true'); $('#'+cid, m).setAttribute('aria-describedby', cid+'-e'); $('#'+cid, m).focus();
            throw new ErroForm([]);
          }
          res = { ok:true, texto:t };
        } else res = { ok:true };
      }}]
    });
  });
}

/* ---------------- formulários ---------------- */
class ErroForm extends Error { constructor(erros){ super('Há campos para corrigir.'); this.erros = erros; } }
function valorInicial(f, v){
  if(v == null || v === '') return '';
  if(f.mask === 'data') return /^\d{4}-\d{2}-\d{2}/.test(v) ? fmtData(v) : v;
  if(f.mask) return MASK[f.mask](v);
  return v;
}
/* fields: { name, label, type, required, mask, ph, dica, options, span, upper, num, sec, text, attrs, opc } */
function formHtml(fields, data={}, pref='f'){
  return `<div class="grid">${fields.map(f => {
    if(f.sec) return `<div class="gsec">${h(f.sec)}</div>`;
    const id = `${pref}-${f.name}`;
    const v = valorInicial(f, data[f.name] ?? f.default ?? '');
    const cls = f.span===4 ? 'full' : f.span ? 's'+f.span : '';
    const desc = [f.dica ? id+'-d' : '', id+'-e'].filter(Boolean).join(' ');
    let inp;
    if(f.type === 'select'){
      const list = typeof f.options === 'function' ? f.options() : f.options;
      inp = `<select id="${id}" name="${f.name}" aria-describedby="${desc}" ${f.required?'aria-required="true"':''}>${f.empty === false ? '' : '<option value="">Selecione</option>'}
        ${list.map(o => `<option value="${h(o.value)}" ${String(o.value)===String(v)?'selected':''}>${h(o.label)}</option>`).join('')}</select>`;
    } else if(f.type === 'textarea'){
      inp = `<textarea id="${id}" name="${f.name}" rows="${f.rows||3}" aria-describedby="${desc}">${h(v)}</textarea>`;
    } else if(f.type === 'checkbox'){
      return `<div class="field ${cls}"><span class="lbl">${h(f.label)}</span><label class="chk" for="${id}"><input type="checkbox" id="${id}" name="${f.name}" ${v?'checked':''}> ${h(f.text||'')}</label>${f.dica?`<span class="dica" id="${id}-d">${h(f.dica)}</span>`:''}</div>`;
    } else {
      const im = { cpf:'numeric', cns:'numeric', cep:'numeric', data:'numeric', tel:'tel' }[f.mask];
      const ac = { nome:'name', email:'email', telefone:'tel' }[f.name];
      inp = `<input type="${f.type||'text'}" id="${id}" name="${f.name}" value="${h(v)}" aria-describedby="${desc}" ${f.required?'aria-required="true"':''}
        ${f.mask?`data-mask="${f.mask}"`:''} ${im?`inputmode="${im}"`:''} ${ac?`autocomplete="${ac}"`:'autocomplete="off"'} ${f.upper?'style="text-transform:uppercase"':''} ${f.attrs||''}>`;
    }
    return `<div class="field ${cls}" data-campo="${f.name}">
      <label for="${id}">${h(f.label)}${f.required ? '' : ' <span class="opc">(opcional)</span>'} <span class="ok-msg" id="${id}-ok"></span></label>
      ${f.dica ? `<span class="dica" id="${id}-d">${h(f.dica)}</span>` : ''}
      <p class="erro-msg hidden" id="${id}-e"></p>${inp}</div>`;
  }).join('')}</div>`;
}
/* lê o formulário; em caso de erro lança ErroForm com a lista {campo, msg} */
function readForm(root, fields, extras, alvoResumo){
  const o = {}, erros = [];
  for(const f of fields){
    if(f.sec) continue;
    const el = $(`[name="${f.name}"]`, root); if(!el) continue;
    let v = f.type === 'checkbox' ? el.checked : el.value.trim();
    const err = msg => erros.push({ campo:f.name, id:el.id, msg });
    if(f.required && v === '') { err(f.msgObrigatorio || `Informe ${f.label.toLowerCase()}.`); continue; }
    if(v === '') v = null;
    if(v !== null && f.mask === 'data'){ const iso = brParaISO(v); if(!iso){ err(`${f.label}: use o formato dd/mm/aaaa, por exemplo 05/03/1980.`); continue; } v = iso; }
    else if(v !== null && ['cpf','cns','tel','cep'].includes(f.mask)) v = dig(v);
    if(v !== null && f.mask === 'tel' && v.length < 10){ err(`${f.label}: informe o DDD e o número, por exemplo (62) 99999-0000.`); continue; }
    if(v !== null && f.mask === 'cep' && v.length !== 8){ err('CEP incompleto: são 8 números, por exemplo 73900-000.'); continue; }
    if(v !== null && f.upper) v = v.toUpperCase();
    if(f.num && v !== null) v = Number(v);
    o[f.name] = v;
  }
  if(extras) extras(o, (campo, msg) => { const el = $(`[name="${campo}"]`, root); erros.push({ campo, id:el?.id, msg }); });
  mostrarErros(root, erros, alvoResumo);
  if(erros.length) throw new ErroForm(erros);
  return o;
}
/* mostra a mensagem ao lado de cada campo e um resumo no topo */
function mostrarErros(root, erros, alvoResumo){
  $$('.erro-msg', root).forEach(e => { e.classList.add('hidden'); e.textContent = ''; });
  $$('[aria-invalid]', root).forEach(e => e.removeAttribute('aria-invalid'));
  $$('.field.tem-erro', root).forEach(e => e.classList.remove('tem-erro'));
  $$('.resumo-erros', root).forEach(e => e.remove());
  if(!erros.length) return;
  erros.forEach(e => {
    const el = e.id ? root.querySelector('#'+CSS.escape(e.id)) : null; if(!el) return;
    el.setAttribute('aria-invalid','true');
    const m = root.querySelector('#'+CSS.escape(e.id+'-e')); if(m){ m.textContent = e.msg; m.classList.remove('hidden'); }
    el.closest('.field')?.classList.add('tem-erro');
  });
  const box = document.createElement('div'); box.className = 'resumo-erros'; box.setAttribute('role','alert'); box.tabIndex = -1;
  box.innerHTML = `<h2>${erros.length === 1 ? 'Há 1 campo para corrigir' : `Há ${erros.length} campos para corrigir`}</h2>
    <ul>${erros.map(e => `<li>${e.id ? `<a href="#${h(e.id)}" data-foco="${h(e.id)}">${h(e.msg)}</a>` : h(e.msg)}</li>`).join('')}</ul>`;
  (alvoResumo || $('.modal-body', root) || root).prepend(box);
  $$('[data-foco]', box).forEach(a => a.onclick = ev => { ev.preventDefault(); root.querySelector('#'+CSS.escape(a.dataset.foco))?.focus(); });
  box.focus();
}

/* ---------------- tabela padronizada ----------------
   colunas: [{ l:'Rótulo', f:linha=>html, v:linha=>valor p/ ordenar, n:true (numérica), cls }]
   Ordenação por clique no cabeçalho, carregar mais, clique na linha e cartões no celular. */
function montarTabela(el, { colunas, linhas, onClick, vazio, pagina=50, ordem=null, rotuloItens='registro(s)', selId=null, id }){
  let lim = pagina, ord = ordem ? { ...ordem } : null;
  const render = () => {
    let l = [...linhas];
    if(ord){ const c = colunas[ord.i]; const val = c.v || (x => String(c.f(x)).replace(/<[^>]+>/g,''));
      l.sort((a, b) => { const x = val(a), y = val(b); if(x === y) return 0; if(x == null) return 1; if(y == null) return -1;
        const r = typeof x === 'number' && typeof y === 'number' ? x - y : String(x).localeCompare(String(y), 'pt-BR', { numeric:true }); return ord.asc ? r : -r; }); }
    if(!l.length){ el.innerHTML = vazio || estado({ titulo:'Nada encontrado', texto:'Ajuste os filtros ou a busca.' }); return; }
    const vis = l.slice(0, lim);
    el.innerHTML = `<div class="tbl-wrap"><table class="resp" ${id?`id="${id}"`:''}><thead><tr>${colunas.map((c, i) => `<th scope="col" class="${c.n?'n':''}" ${c.ordenavel===false?'':`aria-sort="${ord && ord.i===i ? (ord.asc?'ascending':'descending') : 'none'}"`}>
        ${c.ordenavel===false ? h(c.l) : `<button class="ord" data-i="${i}">${h(c.l)}</button>`}</th>`).join('')}</tr></thead>
      <tbody>${vis.map((x, ri) => `<tr ${onClick?`class="clicavel ${selId!=null && x.id===selId?'sel':''}" tabindex="0"`:''} data-ri="${ri}">${colunas.map(c => `<td class="${c.n?'n':''} ${c.cls||''}" data-label="${h(c.ml ?? c.l)}">${c.f(x)}</td>`).join('')}</tr>`).join('')}</tbody></table></div>
      <div class="tbl-info"><span>Mostrando ${num(vis.length)} de ${num(l.length)} ${rotuloItens}</span>${l.length > lim ? `<button class="btn sm" data-mais>Mostrar mais ${Math.min(pagina, l.length-lim)}</button>` : ''}</div>`;
    $$('button.ord', el).forEach(b => b.onclick = () => { const i = +b.dataset.i; ord = ord && ord.i === i ? { i, asc:!ord.asc } : { i, asc:true }; render(); });
    const mais = $('[data-mais]', el); if(mais) mais.onclick = () => { lim += pagina; render(); };
    if(onClick) $$('tbody tr', el).forEach(tr => {
      const go = e => { if(e.target.closest('a,button,input,select,label')) return; onClick(vis[+tr.dataset.ri], tr); };
      tr.onclick = go; tr.onkeydown = e => { if(e.key === 'Enter' || e.key === ' '){ e.preventDefault(); go(e); } };
    });
  };
  render();
  return { render, set(l){ linhas = l; lim = pagina; render(); } };
}

/* pacientes vistos recentemente (por usuário, neste navegador) */
function registrarRecente(p){
  if(!p?.id || !S.perfil) return;
  const k = 'regula_recentes_' + S.perfil.id, l = (store.get(k) || []).filter(x => x !== p.id);
  l.unshift(p.id); store.set(k, l.slice(0, 8));
}
const recentes = () => S.perfil ? (store.get('regula_recentes_' + S.perfil.id) || []) : [];

/* Rotas que funcionam sem login. A PNR-SUS exige que o paciente acompanhe
   a própria situação, e quem chega pelo QR da guia impressa não tem conta
   no sistema. Tudo que estas telas leem passa por função do banco que
   devolve o mínimo e registra a tentativa — ver a migração 002. */
const ROTAS_PUBLICAS = { acompanhar: pgAcompanhar, espera: pgEspera };
const rotaPublica = () => {
  const k = (location.hash || '').replace(/^#\/?/, '').split('?')[0];
  return ROTAS_PUBLICAS[k] ? k : null;
};

async function boot(){
  telaLogin();
  const cfg = window.REGULA_CONFIG;
  if (!cfg?.url || !cfg?.publishableKey) {
    mostrarErroLogin('O acesso ainda está sendo configurado pela administração.');
    document.querySelector('#login-form button').disabled = true;
    return;
  }
  if (!window.supabase) {
    mostrarErroLogin('Não foi possível carregar o serviço de acesso. Recarregue a página.');
    return;
  }
  sb = window.supabase.createClient(cfg.url, cfg.publishableKey);
  sb.auth.onAuthStateChange(event => {
    if(event === 'SIGNED_OUT' && S.user) location.reload();
  });
  // Tela pública pedida no endereço: abre sem exigir sessão.
  const publica = rotaPublica();
  if(publica){
    await abrirPublica(publica);
    window.addEventListener('hashchange', () => {
      const p = rotaPublica();
      if(p) abrirPublica(p); else location.reload();
    });
    return;
  }

  const {data,error} = await sb.auth.getSession();
  if(error) return mostrarErroLogin('Não foi possível recuperar a sessão.');
  if(data.session) await abrirConta(data.session.user);
}

/* Monta a casca mínima para uma tela pública: sem menu lateral, sem perfil,
   sem nada que dependa de usuário autenticado. */
async function abrirPublica(k){
  $('#auth').classList.add('hidden');
  $('#app').classList.remove('hidden');
  $('#sidebar').classList.add('hidden');
  $('#app').style.gridTemplateColumns = '1fr';
  $('#page-actions').innerHTML = '';
  $('#aviso-global').innerHTML = '';
  $('#trilha').textContent = ORGAO;
  const titulos = { acompanhar:'Acompanhar solicitação', espera:'Tempos de espera' };
  $('#page-title').textContent = titulos[k];
  document.title = `${titulos[k]} — Regula Posse`;
  const el = $('#pagina');
  el.innerHTML = carregando();
  try {
    await ROTAS_PUBLICAS[k](el);
  } catch(e){
    el.innerHTML = estado({ tipo:'erro', titulo:'Não foi possível carregar esta tela', texto:h(e.message) });
  }
}

function mostrarErroLogin(texto){ $('#login-msg').textContent = texto; }
async function abrirConta(user){
  const {data:p,error} = await sb.from('perfis').select('*').eq('id', user.id).maybeSingle();
  if(error || !p?.ativo || (['solicitante','executante'].includes(p.papel) && !p.unidade_id)){
    const msg = error ? 'Falha ao consultar permissões. Tente novamente.' : 'Acesso pendente. Solicite a liberação à administração.';
    await sb.auth.signOut({scope:'local'});
    mostrarErroLogin(msg);
    return;
  }
  await entrar(p);
}
function telaLogin(){
  $('#auth').classList.remove('hidden');
  $('#app').classList.add('hidden');
  $('#auth-area').innerHTML = `<h1>Entrar no Regula Posse</h1><form id="login-form">
    <label class="field">E-mail<input name="email" type="email" autocomplete="username" required></label>
    <label class="field">Senha<input name="senha" type="password" autocomplete="current-password" required></label>
    <p id="login-msg" role="alert"></p><button class="btn pri" type="submit">Entrar</button></form>
    <p class="muted" style="margin:18px 0 0;font-size:13px;border-top:1px solid var(--borda);padding-top:14px">
      <b>Você é paciente?</b> Não precisa de conta.
      <a href="#/acompanhar">Acompanhe sua solicitação</a> com o protocolo da sua guia,
      ou veja os <a href="#/espera">tempos de espera por procedimento</a>.</p>`;
  $('#login-form').onsubmit = async e => {
    e.preventDefault();
    if(!sb) return;
    const form=e.currentTarget, btn=form.querySelector('button');
    btn.disabled=true;
    try {
      mostrarErroLogin('');
      const {data,error}=await sb.auth.signInWithPassword({email:form.elements.namedItem('email').value.trim(),password:form.elements.namedItem('senha').value});
      if(error) return mostrarErroLogin('Não foi possível entrar. Confira o e-mail e a senha.');
      form.elements.namedItem('senha').value='';
      await abrirConta(data.user);
    } catch { mostrarErroLogin('Não foi possível acessar o serviço. Tente novamente.'); }
    finally { btn.disabled=false; }
  };
}

async function entrar(perfil){
  S.perfil = perfil; S.user = { id:perfil.id, email:perfil.email };

  await carregarRefs();
  $('#auth').classList.add('hidden'); $('#app').classList.remove('hidden');
  $('#u-nome').textContent = S.perfil.nome;
  $('#u-info').textContent = PAPEIS[S.perfil.papel] + (S.perfil.unidade_id ? ' · ' + nomeUnidade(S.perfil.unidade_id) : '');
  $('#btn-sair').onclick = async () => {
    const {error} = await sb.auth.signOut({scope:'local'});
    if(error) toast('Falha ao sair. Tente novamente.', 'err');
    else { S.user = null; location.reload(); }
  };
  const abrir = v => { $('#sidebar').classList.toggle('aberto', v); $('#menu-fundo').classList.toggle('aberto', v); $('#menu-btn').setAttribute('aria-expanded', v);
    if(v) $('#nav a')?.focus(); };
  $('#menu-btn').onclick = () => abrir(true);
  $('#fechar-menu').onclick = () => { abrir(false); $('#menu-btn').focus(); };
  $('#menu-fundo').onclick = () => abrir(false);
  document.addEventListener('keydown', e => { if(e.key === 'Escape' && $('#sidebar').classList.contains('aberto')){ abrir(false); $('#menu-btn').focus(); } });
  S.fecharMenu = () => abrir(false);
  window.onhashchange = navegar;
  navegar();
}

/* Unidades, procedimentos e vínculos são lidos uma vez no login e ficam em
   memória. Sem recarga, quando o administrador ativa um procedimento as
   sessões já abertas seguem sem vê-lo e ninguém entende o motivo. Então
   relemos quando a aba volta ao foco depois de REFS_VALIDADE_MS, e
   redesenhamos a tela se a assinatura dos cadastros tiver mudado. */
const REFS_VALIDADE_MS = 5 * 60 * 1000;
let refsEm = 0;

async function carregarRefs(){
  const [u, p, up] = await Promise.all([
    q(sb.from('unidades').select('*').order('nome')),
    carregarProcedimentos(),
    q(sb.from('unidade_procedimentos').select('*'))
  ]);
  S.unidades = u; S.procedimentos = p; S.unProc = up;
  refsEm = Date.now();
}
/* Assinatura barata: pega inclusão, exclusão e troca de situação. Uma
   renomeação não entra, e por isso continua valendo recarregar a página. */
const assinaturaRefs = () => [
  S.unidades.length, S.unidades.filter(u => u.ativo).length,
  S.procedimentos.length, S.procedimentos.filter(p => p.ativo).length,
  S.unProc.length,
].join('|');

async function recarregarRefs(){
  if(!S.user || Date.now() - refsEm < REFS_VALIDADE_MS) return;
  const antes = assinaturaRefs();
  try { await carregarRefs(); } catch(e){ return registrarErro(e, 'recarregarRefs'); }
  if(assinaturaRefs() !== antes){
    toast('Os cadastros foram atualizados pela administração.', 'ok');
    navegar();
  }
}
document.addEventListener('visibilitychange', () => { if(!document.hidden) recarregarRefs(); });
async function carregarProcedimentos(){
  const todos = [];
  for(let inicio = 0; ; inicio += 1000){
    const lote = await q(sb.from('procedimentos').select('*').order('id').range(inicio, inicio + 999));
    todos.push(...lote);
    if(lote.length < 1000) break;
  }
  return todos.sort((a,b) => a.nome.localeCompare(b.nome, 'pt-BR'));
}

/* =====================================================================
   TELAS PÚBLICAS (sem login)
   ===================================================================== */

/** URL de acompanhamento, usada no QR Code da guia e no rodapé dela. */
const urlAcompanhar = protocolo =>
  new URL(`#/acompanhar?p=${encodeURIComponent(protocolo)}`, location.href.split('#')[0]).href;

async function pgAcompanhar(el){
  const prot = params().get('p') || '';
  el.innerHTML = `
    <div class="card" style="max-width:560px;margin:0 auto">
      <div class="card-h"><h2>Acompanhar sua solicitação</h2></div>
      <p class="muted">Informe o número do protocolo, que está na sua guia, e a data de
        nascimento do paciente. Pedimos os dois dados para proteger a informação de saúde.</p>
      <form id="ac-f" novalidate>
        <div class="grid" style="grid-template-columns:repeat(2,minmax(0,1fr))">
          <div class="field">
            <label for="ac-p">Número do protocolo</label>
            <span class="dica" id="ac-p-d">Como está na guia, por exemplo 2026000123.</span>
            <input id="ac-p" inputmode="numeric" autocomplete="off" aria-describedby="ac-p-d" value="${h(prot)}">
          </div>
          <div class="field">
            <label for="ac-n">Data de nascimento</label>
            <span class="dica" id="ac-n-d">dd/mm/aaaa</span>
            <input id="ac-n" data-mask="data" inputmode="numeric" autocomplete="off" aria-describedby="ac-n-d" placeholder="dd/mm/aaaa">
          </div>
        </div>
        <p id="ac-erro" class="erro-msg hidden" role="alert"></p>
        <div class="acoes" style="margin-top:14px">
          <button class="btn pri lg" type="submit">Consultar</button>
          <a class="btn" href="#/espera">Ver tempos de espera</a>
        </div>
      </form>
      <div id="ac-res" aria-live="polite"></div>
    </div>`;

  const erro = msg => { const e = $('#ac-erro'); e.textContent = msg; e.classList.toggle('hidden', !msg); };

  async function consultar(){
    erro('');
    $('#ac-res').innerHTML = '';
    const p = dig($('#ac-p').value);
    const nasc = brParaISO($('#ac-n').value);
    if(!p) return erro('Informe o número do protocolo que está na sua guia.');
    if(!nasc) return erro('Informe a data de nascimento no formato dd/mm/aaaa.');

    const btn = $('#ac-f button[type=submit]');
    const r = await ocupado(btn, () => q(sb.rpc('consultar_protocolo', { p_protocolo: p, p_nascimento: nasc })));
    const d = Array.isArray(r) ? r[0] : r;

    if(!d || d.resultado === 'incompleto') return erro('Informe o protocolo e a data de nascimento.');
    if(d.resultado === 'limite') return erro('Tivemos muitas consultas em pouco tempo. Aguarde alguns minutos e tente de novo.');
    if(d.resultado === 'nao_encontrado') return erro('Não encontramos esse protocolo com essa data de nascimento. Confira os dois dados na sua guia.');

    const linha = (rot, val) => val ? `<div><dt>${h(rot)}</dt><dd>${val}</dd></div>` : '';
    $('#ac-res').innerHTML = `
      <h3 style="margin-top:22px">Protocolo ${h(d.protocolo)}</h3>
      <dl class="dl">
        ${linha('Situação', `<b>${h(d.situacao)}</b>`)}
        ${linha('Procedimento', h(d.procedimento))}
        ${linha('Data do pedido médico', fmtData(d.data_pedido))}
        ${linha('Tempo desde o pedido', d.dias_desde_pedido != null ? `${num(d.dias_desde_pedido)} dia(s)` : '')}
        ${linha('Posição na fila deste procedimento', d.posicao != null ? `${num(d.posicao)}º` : '')}
        ${d.agendada_data ? linha('Atendimento marcado', `<b>${h(dataExtenso(d.agendada_data))} às ${h(fmtHora(d.agendada_hora))}</b>`) : ''}
        ${linha('Local', h(d.local_nome))}
        ${linha('Endereço', h(d.local_endereco))}
        ${linha('Telefone do local', d.local_telefone ? h(fTel(d.local_telefone)) : '')}
        ${linha('Motivo informado pela regulação', h(d.parecer))}
      </dl>
      ${d.posicao != null ? alerta('info', 'A posição na fila muda conforme chegam casos de maior risco clínico, '
          + 'conforme o protocolo da regulação municipal. Ela é uma estimativa, não uma garantia de data.') : ''}
      ${d.agendada_data ? alerta('warn', 'Se não puder comparecer, avise a Secretaria de Saúde com antecedência '
          + 'para que a vaga seja remanejada para outro paciente.') : ''}`;
  }

  $('#ac-f').onsubmit = e => { e.preventDefault(); consultar().catch(err => erro(err.message)); };
  if(prot) $('#ac-n').focus();
}

async function pgEspera(el){
  const linhas = await q(sb.rpc('tempos_medios_espera'));
  if(!linhas.length){
    el.innerHTML = estado({ titulo:'Nenhuma solicitação aguardando no momento',
      texto:'Quando houver fila, os tempos de espera aparecem aqui.' });
    return;
  }
  const total = linhas.reduce((a, l) => a + Number(l.aguardando), 0);
  el.innerHTML = `
    <div class="card">
      <div class="card-h"><h2>Tempos de espera por procedimento</h2>
        <span class="sub">${num(total)} solicitação(ões) aguardando · atualizado agora</span></div>
      <p class="muted">Contagem a partir da data do pedido médico. Não há nenhum dado pessoal
        nesta página. Para saber da sua solicitação, use o <a href="#/acompanhar">acompanhamento por protocolo</a>.</p>
      <div id="esp-tab"></div>
    </div>`;
  montarTabela($('#esp-tab'), {
    rotuloItens: 'procedimento(s)',
    ordem: { i:1, asc:false },
    linhas,
    colunas: [
      { l:'Procedimento', f:l => h(l.procedimento) + (l.exige_regulacao ? ' ' + tagReg() : ''), v:l => l.procedimento },
      { l:'Aguardando',   n:true, f:l => num(l.aguardando),                      v:l => Number(l.aguardando) },
      { l:'Espera média', n:true, f:l => `${num(l.espera_media_dias)} dia(s)`,   v:l => Number(l.espera_media_dias) },
      { l:'Maior espera', n:true, f:l => `${num(l.espera_maxima_dias)} dia(s)`,  v:l => Number(l.espera_maxima_dias) },
    ],
  });
}

/* =====================================================================
   ROTAS, MENU E PERMISSÕES
   As permissões repetem as regras do banco (schema.sql). Esconder o menu
   não basta: navegar() também bloqueia o acesso direto pelo endereço.
   ===================================================================== */
const TODOS = ['admin','solicitante','agendador','regulador','executante'];
const ROTAS = {
  inicio:       { t:'Painel',                     ic:'inicio',        g:'',               papeis:TODOS,                                         r:() => pgInicio },
  solicitacao:  { t:'Nova solicitação',           ic:'solicitacao',   g:'Atendimento',    papeis:['admin','solicitante','agendador','regulador'], r:() => pgSolicitacao },
  solicitacoes: { t:'Solicitações',               ic:'pacientes',     g:'Atendimento',    papeis:['admin','solicitante','agendador','regulador'], r:() => pgSolicitacoes },
  agendamento:  { t:'Agendamento',                ic:'agendamento',   g:'Atendimento',    papeis:['admin','solicitante','agendador','regulador'], r:() => pgAgendamento, cnt:'agendar' },
  confirmacao:  { t:'Confirmação de atendimento', ic:'confirmacao',   g:'Atendimento',    papeis:['admin','agendador','regulador','executante'],  r:() => pgConfirmacao, cnt:'confirmar' },
  regulacao:    { t:'Análise regulatória',        ic:'regulacao',     g:'Regulação',      papeis:['admin','regulador'],                           r:() => pgRegulacao, cnt:'regular' },
  fila:         { t:'Fila de espera',             ic:'fila',          g:'Regulação',      papeis:['admin','regulador','agendador'],               r:() => pgFila },
  vulnerabilidade:{ t:'Critérios de vulnerabilidade', ic:'regulacao', g:'Regulação',   papeis:['admin'],                                       r:() => pgVulnerabilidade },
  agendas:      { t:'Agendas e vagas',            ic:'agendas',       g:'Administração',  papeis:['admin','agendador','regulador'],               r:() => pgAgendas },
  locais:       { t:'Locais e unidades',          ic:'locais',        g:'Administração',  papeis:['admin','agendador','regulador'],               r:() => pgLocais },
  procedimentos:{ t:'Procedimentos',              ic:'procedimentos', g:'Administração',  papeis:['admin','agendador','regulador'],               r:() => pgProcedimentos },
  pacientes:    { t:'Pacientes',                  ic:'pacientes',     g:'Administração',  papeis:['admin','solicitante','agendador','regulador'], r:() => pgPacientes },
  usuarios:     { t:'Usuários',                   ic:'usuarios',      g:'Administração',  papeis:['admin'],                                       r:() => pgUsuarios },
  mira:         { t:'Envio ao Ministério (MIRA)', ic:'relatorios',    g:'Administração',  papeis:['admin','regulador'],                           r:() => pgMira },
  auditoria:    { t:'Auditoria',                  ic:'usuarios',      g:'Administração',  papeis:['admin'],                                       r:() => pgAuditoria },
  relatorios:   { t:'Relatórios',                 ic:'relatorios',    g:'Relatórios',     papeis:TODOS,                                         r:() => pgRelatorios },
};
const pode = k => ROTAS[k] && ROTAS[k].papeis.includes(papel());

function montarMenu(atual){
  let sec = null, html = '';
  for(const [k, r] of Object.entries(ROTAS)){
    if(!pode(k)) continue;
    if(r.g !== sec){ sec = r.g; if(sec) html += `<div class="sec" role="presentation">${h(sec)}</div>`; }
    html += `<a href="#/${k}" ${k===atual?'aria-current="page"':''}><span class="ic"><img src="${ICONES[r.ic]}" alt=""></span><span>${h(r.t)}</span>${r.cnt?`<span class="cnt hidden" data-cnt="${r.cnt}"></span>`:''}</a>`;
  }
  $('#nav').innerHTML = html;
  $$('#nav a').forEach(a => a.addEventListener('click', () => S.fecharMenu && S.fecharMenu()));
  atualizarContadores();
}

/* contadores só onde ajudam a decidir o que fazer agora */
async function atualizarContadores(){
  const els = $$('[data-cnt]'); if(!els.length) return;
  const l = await fetchAll(() => sb.from('vw_solicitacoes').select('status,exige_regulacao,vaga_data,unidade_executante_id').order('id'));
  const hoje = hojeISO();
  const n = {
    agendar: l.filter(s => s.status === 'autorizada' || (s.status === 'pendente' && !s.exige_regulacao)).length,
    regular: l.filter(s => s.status === 'pendente' && s.exige_regulacao).length,
    confirmar: papel() === 'executante' ? l.filter(s => s.status === 'agendada' && s.vaga_data <= hoje).length : 0,
  };
  const desc = { agendar:'aguardando agendamento', regular:'aguardando análise', confirmar:'aguardando confirmação' };
  els.forEach(e => { const v = n[e.dataset.cnt]; e.textContent = v; e.classList.toggle('hidden', !v); e.setAttribute('aria-label', `${v} ${desc[e.dataset.cnt]}`); e.title = `${v} ${desc[e.dataset.cnt]}`; });
}

S.hist = [];

/* Cada chamada de navegar() recebe um número de geração. Como o render da
   tela é assíncrono, dois cliques rápidos no menu disparam dois renders em
   paralelo e o mais lento sobrescreveria o mais novo — sintoma típico em
   conexão ruim. Depois de cada await conferimos se ainda somos a navegação
   corrente; se não, saímos sem tocar na tela. */
let geracao = 0;
async function navegar(){
  const g = ++geracao;
  let hash = location.hash || '#/inicio';
  let k = hash.replace(/^#\/?/, '').split('?')[0] || 'inicio';
  // compatibilidade com endereços da versão anterior
  if(k === 'agendas' && /aba=locais/.test(hash)) { location.replace('#/locais'); return; }
  if(k === 'agendas' && /aba=procedimentos/.test(hash)) { location.replace('#/procedimentos'); return; }
  if(!ROTAS[k]) k = 'inicio';
  if(S.hist[S.hist.length-1] !== hash){
    if(S.hist.length > 1 && S.hist[S.hist.length-2] === hash) S.hist.pop(); else S.hist.push(hash);
    if(S.hist.length > 20) S.hist.shift();
  }
  montarMenu(k);
  const r = ROTAS[k];
  document.title = `${r.t} — Regula Posse`;
  $('#trilha').textContent = r.g ? `${r.g} › ${r.t}` : 'Regula Posse';
  $('#page-title').textContent = r.t;
  $('#page-actions').innerHTML = '';
  $('#aviso-global').innerHTML = S.avisoPendente || ''; S.avisoPendente = '';
  const el = $('#pagina');
  // contexto: voltar para a tela anterior quando veio de outra tela
  const ant = S.hist.length > 1 ? S.hist[S.hist.length-2] : null;
  const kAnt = ant ? ant.replace(/^#\/?/, '').split('?')[0] : null;
  const voltar = ant && kAnt !== k && ROTAS[kAnt] && pode(kAnt) && hash.includes('?')
    ? `<a class="btn sm link voltar no-print" href="${h(ant)}">‹ Voltar para ${h(ROTAS[kAnt].t)}</a>` : '';
  if(!pode(k)){
    el.innerHTML = estado({ tipo:'permissao', titulo:'Acesso não permitido para o seu perfil',
      texto:`A tela <b>${h(r.t)}</b> não está disponível para o perfil <b>${h(PAPEIS[papel()])}</b>. Se precisar dela, peça ao administrador para ajustar seu perfil.`,
      acoes:[{ label:'Ir para o Painel', href:'#/inicio', cls:'pri' }] });
    return;
  }
  el.innerHTML = voltar;
  const box = document.createElement('div'); box.innerHTML = carregando(); el.appendChild(box);
  try {
    await r.r()(box);
    if(g !== geracao) return;          // uma navegação mais nova assumiu a tela
  } catch(e){
    if(g !== geracao) return;
    registrarErro(e, 'navegar:' + k);
    el.innerHTML = voltar + estado({ tipo:'erro', titulo:'Não foi possível carregar esta tela', texto:h(e.message), acoes:[{ label:'Tentar novamente', id:'retry', cls:'pri' }] });
    $('[data-estado-acao=retry]', el).onclick = navegar;
  }
  if(S.focarTitulo !== false) $('#page-title').focus({ preventScroll:true });
  window.scrollTo(0, 0);
}
const ir = hash => { if(location.hash === hash) navegar(); else location.hash = hash; };
/* aviso persistente mostrado na próxima tela */
const avisoNaProxima = (html, tipo='ok', titulo='') => { S.avisoPendente = `<div class="alert ${tipo}" role="status"><span class="ai" aria-hidden="true">${{ ok:'✓', err:'⚠', warn:'!', info:'i' }[tipo]}</span><div>${titulo?`<b class="t">${h(titulo)}</b>`:''}${html}</div><button class="btn sm link" aria-label="Fechar aviso" data-acao="fechar-alerta">Fechar</button></div>`; };

function acaoTopo(label, cls, fn, ico){
  const b = document.createElement('button'); b.className = 'btn '+cls; b.type = 'button';
  b.innerHTML = (ico ? `<img class="ico" src="${ICONES[ico]}" alt="">` : '') + h(label); b.onclick = fn;
  $('#page-actions').appendChild(b);
  return b;
}

/* =====================================================================
   PAINEL — central de tarefas por perfil
   Todo indicador diz o que conta e leva à lista correspondente.
   ===================================================================== */
const kpi = ({ l, v, s='', href, c='azul' }) => href
  ? `<a class="kpi c-${c}" href="${href}"><span class="l">${h(l)}</span><span class="v">${num(v)}</span><span class="s">${s}</span><span class="ir" aria-hidden="true">Ver lista ›</span></a>`
  : `<div class="kpi c-${c}"><span class="l">${h(l)}</span><span class="v">${typeof v === 'number' ? num(v) : h(v)}</span><span class="s">${s}</span></div>`;
const barras = (pares, cls) => {
  if(!pares.length) return '<p class="muted">Sem registros.</p>';
  const max = Math.max(...pares.map(p => p[1]), 1);
  return pares.map(([k, v, c]) => `<div class="bar ${c||cls||''}"><span class="n" title="${h(k)}">${h(k)}</span><span class="t" aria-hidden="true"><i style="width:${(v/max*100).toFixed(0)}%"></i></span><span class="c">${num(v)}</span></div>`).join('');
};
const agendavel = s => s.status === 'autorizada' || (s.status === 'pendente' && !s.exige_regulacao);
const emRegulacao = s => s.status === 'pendente' && s.exige_regulacao;

async function pgInicio(el){
  const hoje = hojeISO(), ini = inicioMes();
  const rows = await fetchAll(() => sb.from('vw_solicitacoes').select('*').order('id'));
  const cab = `<div class="periodo"><span>Hoje: <b>${dataExtenso(hoje)}</b></span><span>Indicadores do mês: <b>${fmtData(ini)} a ${fmtData(hoje)}</b></span>
    ${papel()==='solicitante' || papel()==='executante' ? `<span>Unidade: <b>${h(nomeUnidade(S.perfil.unidade_id))}</b></span>` : '<span>Abrangência: <b>todas as unidades</b></span>'}</div>`;
  const semUni = papel() !== 'admin' && !S.perfil.unidade_id ? alerta('warn', 'Seu usuário ainda não está vinculado a uma unidade. Peça ao administrador para fazer o vínculo em <b>Usuários</b>.', 'Cadastro incompleto') : '';
  const fn = { solicitante:painelAtendente, regulador:painelRegulador, agendador:painelAgendador, executante:painelExecutante, admin:painelAdmin }[papel()];
  el.innerHTML = semUni + cab + await fn(rows, hoje, ini);
  $$('[data-abrir]', el).forEach(b => b.onclick = () => abrirSolicitacao(+b.dataset.abrir, () => navegar()));
  const f = $('#p-guia-f', el);
  if(f) f.onsubmit = e => { e.preventDefault(); const g = dig($('#p-guia', el).value); if(g) ir(`#/confirmacao?guia=${g}`); else $('#p-guia', el).focus(); };
}

const atalhos = l => `<div class="atalhos">${l.filter(a => pode(a[0])).map(([k, t, d, pri]) =>
  `<a class="atalho ${pri?'pri':''}" href="#/${k}"><img src="${ICONES[ROTAS[k].ic]}" alt=""><span><b>${h(t)}</b><small>${h(d)}</small></span></a>`).join('')}</div>`;

function tabelaSimples(cols, linhas, vazio='Nada para mostrar.'){
  if(!linhas.length) return `<p class="muted">${h(vazio)}</p>`;
  return `<div class="tbl-wrap"><table class="resp"><thead><tr>${cols.map(c => `<th scope="col" class="${c.n?'n':''}">${h(c.l)}</th>`).join('')}</tr></thead>
    <tbody>${linhas.map(x => `<tr>${cols.map(c => `<td class="${c.n?'n':''}" data-label="${h(c.l)}">${c.f(x)}</td>`).join('')}</tr>`).join('')}</tbody></table></div>`;
}
const linkSol = s => `<button class="btn link sm" data-abrir="${s.id}" style="padding:0;min-height:0">${h(s.protocolo)}</button>`;

/* ---------- Atendente ---------- */
async function painelAtendente(rows, hoje, ini){
  const doMes = rows.filter(s => s.created_at.slice(0,10) >= ini);
  const dev = rows.filter(s => s.status === 'devolvida');
  const ag7 = rows.filter(s => s.status === 'agendada' && s.vaga_data >= hoje && s.vaga_data <= addDias(hoje, 7));
  const rec = [...rows].sort((a, b) => b.created_at.localeCompare(a.created_at)).slice(0, 8);
  const ids = recentes();
  const pacs = ids.length ? await q(sb.from('pacientes').select('id,nome,data_nascimento,cpf').in('id', ids)) : [];
  pacs.sort((a, b) => ids.indexOf(a.id) - ids.indexOf(b.id));
  return `
    ${dev.length ? alerta('warn', `${dev.length === 1 ? 'Uma solicitação foi devolvida' : `${dev.length} solicitações foram devolvidas`} pelo regulador e ${dev.length === 1 ? 'precisa' : 'precisam'} de correção. <a href="#/solicitacoes?status=devolvida">Ver devolvidas</a>`, 'Ação necessária') : ''}
    ${atalhos([['solicitacao','Nova solicitação','Cadastrar paciente e pedido',1],['agendamento','Agendar','Marcar consulta ou exame'],['pacientes','Buscar paciente','Ficha e histórico'],['solicitacoes','Solicitações','Acompanhar pedidos da unidade']])}
    <div class="kpis">
      ${kpi({ l:'Registradas no mês', v:doMes.length, s:'solicitações criadas pela unidade no mês atual', href:`#/solicitacoes?de=${ini}` })}
      ${kpi({ l:'Devolvidas para correção', v:dev.length, s:'o regulador pediu mais informações', href:'#/solicitacoes?status=devolvida', c:'vermelho' })}
      ${kpi({ l:'Aguardando agendamento', v:rows.filter(agendavel).length, s:'prontas para escolher vaga', href:'#/agendamento', c:'amarelo' })}
      ${kpi({ l:'Aguardando regulação', v:rows.filter(emRegulacao).length, s:'em análise pelo regulador', href:'#/solicitacoes?status=regulacao', c:'roxo' })}
      ${kpi({ l:'Agendadas — próximos 7 dias', v:ag7.length, s:`de ${fmtData(hoje)} a ${fmtData(addDias(hoje,7))}`, href:'#/solicitacoes?status=agendada', c:'teal' })}
    </div>
    <div>
      <section class="card"><div class="card-h"><h2>Solicitações recentes</h2><span class="spacer"></span><a class="btn sm" href="#/solicitacoes">Ver todas</a></div>
        ${tabelaSimples([{ l:'Protocolo', f:linkSol }, { l:'Paciente', f:s => h(s.paciente_nome) }, { l:'Procedimento', f:s => h(s.procedimento_nome) }, { l:'Situação', f:badgeSt }], rec, 'Nenhuma solicitação registrada.')}</section>
      <section class="card"><div class="card-h"><h2>Pacientes vistos recentemente</h2><span class="sub">neste navegador</span></div>
        ${pacs.length ? `<ul class="lista-alertas">${pacs.map(p => `<li><span style="flex:1"><b>${h(p.nome)}</b><span class="sub-linha">${fmtData(p.data_nascimento)} · CPF ${cpfOculto(p.cpf)}</span></span>
          ${pode('solicitacao') ? `<a class="btn sm" href="#/solicitacao?pac=${p.id}">Nova solicitação</a>` : ''}</li>`).join('')}</ul>`
          : '<p class="muted">Os pacientes que você localizar ou cadastrar aparecem aqui para acesso rápido.</p>'}</section>
    </div>`;
}

/* ---------- Regulador ---------- */
async function painelRegulador(rows, hoje, ini){
  const analise = rows.filter(emRegulacao), dev = rows.filter(s => s.status === 'devolvida'), aut = rows.filter(s => s.status === 'autorizada');
  const feitas = rows.filter(s => s.data_regulacao && s.data_regulacao.slice(0,10) >= ini);
  const espera = rows.filter(s => ['pendente','autorizada','devolvida'].includes(s.status)).sort((a, b) => b.dias_espera - a.dias_espera).slice(0, 8);
  const maior = analise.length ? Math.max(...analise.map(s => s.dias_espera)) : 0;
  return `
    ${atalhos([['regulacao','Analisar solicitações','Autorizar, devolver ou negar',1],['fila','Fila de espera','Toda a fila, com filtros'],['relatorios','Relatórios','Espera e produção']])}
    <div class="kpis">
      ${kpi({ l:'Aguardando análise', v:analise.length, s:`procedimentos que exigem regulação · maior espera: ${maior} dia(s)`, href:'#/regulacao', c:'roxo' })}
      ${kpi({ l:'Devolvidas aguardando correção', v:dev.length, s:'com a unidade solicitante', href:'#/fila?status=devolvida', c:'vermelho' })}
      ${kpi({ l:'Autorizadas aguardando vaga', v:aut.length, s:'liberadas para o agendamento', href:'#/fila?status=autorizada', c:'amarelo' })}
      ${kpi({ l:'Análises feitas no mês', v:feitas.length, s:`autorizadas, devolvidas ou negadas desde ${fmtData(ini)}` })}
    </div>
    <div>
      <section class="card"><h2 style="font-size:16px">Aguardando análise, por classificação de risco</h2>
        ${barras(Object.entries(PRIORIDADES).map(([k, p]) => [`${p.s} ${p.l} — ${p.d}`, analise.filter(s => s.prioridade === k).length, { vermelho:'pr-v', amarelo:'pr-a', verde:'pr-g', azul:'pr-b' }[k]]))}
        <p class="muted" style="margin:8px 0 0;font-size:13px">Contagem das solicitações com situação "Aguardando regulação".</p></section>
      <section class="card"><div class="card-h"><h2>Maiores tempos de espera</h2><span class="sub">aguardando regulação, vaga ou correção</span></div>
        ${tabelaSimples([{ l:'Protocolo', f:linkSol }, { l:'Paciente', f:s => h(s.paciente_nome) }, { l:'Procedimento', f:s => h(s.procedimento_nome) },
          { l:'Risco', f:s => badgePrio(s.prioridade) }, { l:'Espera', n:1, f:s => `${s.dias_espera} dia(s)` }, { l:'Situação', f:badgeSt }], espera, 'Fila vazia.')}</section>
    </div>`;
}

/* ---------- Agendador ---------- */
async function painelAgendador(rows, hoje){
  const vagas = await fetchAll(() => sb.from('vagas').select('id,data,hora,status,unidade_executante_id,procedimento_id,profissional').gte('data', hoje).lte('data', addDias(hoje, 60)).order('id'));
  const fila = rows.filter(agendavel);
  const livres30 = vagas.filter(v => v.status === 'livre' && v.data <= addDias(hoje, 30)).length;
  const porProc = {}; fila.forEach(s => (porProc[s.procedimento_id] ||= []).push(s));
  const semVaga = Object.entries(porProc).filter(([pid]) => !vagas.some(v => v.procedimento_id === +pid && v.status === 'livre'))
    .map(([pid, l]) => ({ pid:+pid, n:l.length, max:Math.max(...l.map(s => s.dias_espera)) })).sort((a, b) => b.n - a.n);
  const prox = {}; vagas.filter(v => v.data <= addDias(hoje, 7)).forEach(v => {
    const k = [v.data, v.unidade_executante_id, v.procedimento_id, v.profissional || ''].join('|');
    const g = (prox[k] ||= { ...v, tot:0, liv:0 }); g.tot++; if(v.status === 'livre') g.liv++; });
  const proxL = Object.values(prox).sort((a, b) => (a.data + a.hora).localeCompare(b.data + b.hora)).slice(0, 12);
  return `
    ${atalhos([['agendamento','Agendar a fila','Escolher vaga para quem aguarda',1],['agendas','Agendas e vagas','Calendário e cadastro de agenda'],['fila','Fila de espera','Toda a fila, com filtros']])}
    <div class="kpis">
      ${kpi({ l:'Aguardando agendamento', v:fila.length, s:'solicitações prontas para receber vaga', href:'#/agendamento', c:'amarelo' })}
      ${kpi({ l:'Vagas livres — próximos 30 dias', v:livres30, s:`de ${fmtData(hoje)} a ${fmtData(addDias(hoje,30))}`, href:'#/agendas', c:'verde' })}
      ${kpi({ l:'Procedimentos sem vaga', v:semVaga.length, s:'têm fila, mas nenhuma vaga livre nos próximos 60 dias', href:'#sem-vaga', c:'vermelho' })}
      ${kpi({ l:'Aguardando regulação', v:rows.filter(emRegulacao).length, s:'ainda não podem ser agendadas', href:'#/fila?status=regulacao', c:'roxo' })}
    </div>
    <div>
      <section class="card" id="sem-vaga" tabindex="-1"><div class="card-h"><h2>Fila sem vaga disponível</h2><span class="sub">próximos 60 dias</span></div>
        ${tabelaSimples([{ l:'Procedimento', f:x => h(nomeProc(x.pid)) }, { l:'Aguardando', n:1, f:x => num(x.n) }, { l:'Maior espera', n:1, f:x => `${x.max} dia(s)` },
          { l:'', f:x => pode('agendas') ? `<a class="btn sm" href="#/agendas">Cadastrar agenda</a>` : '' }], semVaga, 'Todos os procedimentos com fila têm vagas livres.')}</section>
      <section class="card"><div class="card-h"><h2>Próximas agendas</h2><span class="sub">${fmtData(hoje)} a ${fmtData(addDias(hoje,7))}</span><span class="spacer"></span><a class="btn sm" href="#/agendas">Calendário</a></div>
        ${tabelaSimples([{ l:'Data', f:v => `${diaSemana(v.data)} ${fmtData(v.data)}` }, { l:'Local', f:v => h(nomeUnidade(v.unidade_executante_id)) },
          { l:'Procedimento / profissional', f:v => `${h(nomeProc(v.procedimento_id))}<small>${h(v.profissional || 'Sem profissional')}</small>` },
          { l:'Livres / total', n:1, f:v => `${v.liv} / ${v.tot}` }], proxL, 'Nenhuma agenda nos próximos 7 dias.')}</section>
    </div>`;
}

/* ---------- Local de atendimento ---------- */
async function painelExecutante(rows, hoje){
  const dia = rows.filter(s => s.vaga_data === hoje && ['agendada','realizada','faltou'].includes(s.status)).sort((a, b) => a.vaga_hora.localeCompare(b.vaga_hora));
  const pend = rows.filter(s => s.status === 'agendada' && s.vaga_data <= hoje);
  return `
    <section class="card"><form id="p-guia-f" class="guia-busca" role="search">
      <div class="field"><label for="p-guia">Confirmar atendimento — número da guia</label><input id="p-guia" data-mask="guia" inputmode="numeric" autocomplete="off" placeholder="Ex.: 26000015"></div>
      <button class="btn pri lg" type="submit">Buscar guia</button></form></section>
    <div class="kpis">
      ${kpi({ l:'Agenda de hoje', v:dia.length, s:`atendimentos marcados para ${fmtData(hoje)}`, href:'#/confirmacao' })}
      ${kpi({ l:'Aguardando confirmação', v:pend.length, s:'agendados até hoje sem registro de realização ou falta', href:'#/confirmacao?pend=1', c:'amarelo' })}
      ${kpi({ l:'Realizados hoje', v:dia.filter(s => s.status === 'realizada').length, s:'execução confirmada', href:'#/confirmacao', c:'verde' })}
      ${kpi({ l:'Faltas hoje', v:dia.filter(s => s.status === 'faltou').length, s:'falta registrada', href:'#/confirmacao', c:'vermelho' })}
    </div>
    <section class="card"><div class="card-h"><h2>Agenda de hoje</h2><span class="sub">${dataExtenso(hoje)}</span><span class="spacer"></span><a class="btn sm" href="#/confirmacao">Abrir confirmação</a></div>
      ${tabelaSimples([{ l:'Hora', f:s => `<b>${fmtHora(s.vaga_hora)}</b>` }, { l:'Guia', f:s => `<a href="#/confirmacao?guia=${h(s.numero_guia)}">${h(s.numero_guia)}</a>` },
        { l:'Paciente', f:s => h(s.paciente_nome) }, { l:'Procedimento', f:s => h(s.procedimento_nome) }, { l:'Situação', f:badgeSt }], dia, 'Nenhum atendimento marcado para hoje.')}</section>`;
}

/* ---------- Administrador ---------- */
async function painelAdmin(rows, hoje, ini){
  const [vMes, v30, perfis] = await Promise.all([
    fetchAll(() => sb.from('vagas').select('id,status').gte('data', ini).lte('data', hoje).order('id')),
    fetchAll(() => sb.from('vagas').select('id,status,procedimento_id').gte('data', hoje).lte('data', addDias(hoje, 30)).order('id')),
    q(sb.from('perfis').select('*'))
  ]);
  const prodMes = rows.filter(s => s.vaga_data && s.vaga_data >= ini && s.vaga_data <= hoje);
  const real = prodMes.filter(s => s.status === 'realizada').length, falt = prodMes.filter(s => s.status === 'faltou').length;
  const ocup = vMes.filter(v => v.status === 'ocupada').length, bloq = vMes.filter(v => v.status === 'bloqueada').length;
  const ativosExec = locaisExec(), procsAtivos = S.procedimentos.filter(p => p.ativo);
  const filaProcs = new Set(rows.filter(agendavel).map(s => s.procedimento_id));
  const alertas = [
    [ativosExec.filter(u => !procsDoLocal(u.id).length), 'locais de atendimento sem procedimentos cadastrados', '#/locais'],
    [procsAtivos.filter(p => !S.unProc.some(x => x.procedimento_id === p.id)), 'procedimentos sem local de atendimento', '#/procedimentos'],
    [procsAtivos.filter(p => !p.codigo_sigtap), 'procedimentos sem código SIGTAP', '#/procedimentos'],
    [S.unidades.filter(u => u.ativo && !u.cnes), 'unidades sem CNES', '#/locais'],
    [perfis.filter(p => p.ativo && !p.unidade_id && p.papel !== 'admin'), 'usuários sem unidade vinculada', '#/usuarios'],
    [[...filaProcs].filter(pid => !v30.some(v => v.procedimento_id === pid && v.status === 'livre')), 'procedimentos com fila e sem vaga livre nos próximos 30 dias', '#/agendas'],
  ].filter(a => a[0].length);
  return `
    <div class="kpis">
      ${kpi({ l:'Solicitações registradas', v:rows.filter(s => s.created_at.slice(0,10) >= ini).length, s:'no mês atual', href:`#/fila?de=${ini}&status=` })}
      ${kpi({ l:'Fila atual', v:rows.filter(s => agendavel(s) || emRegulacao(s)).length, s:`${rows.filter(emRegulacao).length} em regulação · ${rows.filter(agendavel).length} aguardando vaga`, href:'#/fila', c:'amarelo' })}
      ${kpi({ l:'Realizados no mês', v:real, s:'atendimentos com execução confirmada', href:'#/relatorios', c:'verde' })}
      ${kpi({ l:'Faltas no mês', v:falt, s:`absenteísmo: ${pct(falt, real + falt)} (faltas ÷ realizados + faltas)`, href:'#/relatorios', c:'vermelho' })}
      ${kpi({ l:'Ocupação das vagas no mês', v:pct(ocup, vMes.length - bloq), s:`${num(ocup)} ocupadas de ${num(vMes.length - bloq)} disponíveis (sem bloqueadas)`, c:'teal' })}
      ${kpi({ l:'Vagas livres — próximos 30 dias', v:v30.filter(v => v.status === 'livre').length, s:`até ${fmtData(addDias(hoje,30))}`, href:'#/agendas', c:'verde' })}
    </div>
    <div class="cols">
      <section class="card"><div class="card-h"><h2>Alertas de cadastro</h2><span class="sub">itens que atrapalham a regulação</span></div>
        ${alertas.length ? `<ul class="lista-alertas">${alertas.map(([l, t, href]) => `<li><span class="badge st-faltou">${l.length}</span><span style="flex:1">${h(t)}</span><a class="btn sm" href="${href}">Corrigir</a></li>`).join('')}</ul>`
          : alerta('ok', 'Nenhum problema de cadastro encontrado.')}</section>
      <section class="card"><h2 style="font-size:16px">Administração</h2>
        ${atalhos([['agendas','Agendas e vagas','Calendário e geração de vagas'],['locais','Locais e unidades','Unidades e o que cada local realiza'],['procedimentos','Procedimentos','SIGTAP e regulação'],['usuarios','Usuários','Perfis e vínculos'],['relatorios','Relatórios','Produção, fila e vagas']])}</section>
    </div>`;
}

/* =====================================================================
   PACIENTE — cadastro, busca e ficha
   ===================================================================== */
const F_PACIENTE = [
  { sec:'Dados pessoais' },
  { name:'nome', label:'Nome completo', required:true, span:3, upper:true, dica:'Como está no documento.' },
  { name:'sexo', label:'Sexo', type:'select', required:true, options:[{value:'F',label:'Feminino'},{value:'M',label:'Masculino'},{value:'I',label:'Não informado'}] },
  { name:'nome_social', label:'Nome social', span:2 },
  { name:'data_nascimento', label:'Data de nascimento', required:true, mask:'data', dica:'dd/mm/aaaa — ex.: 05/03/1980' },
  { name:'cpf', label:'CPF', mask:'cpf', dica:'Informe CPF ou Cartão SUS (pelo menos um).' },
  { name:'cns', label:'Cartão SUS (CNS)', mask:'cns', span:2, dica:'15 números, ex.: 700 0000 0000 0000' },
  { name:'nome_mae', label:'Nome da mãe', span:2, upper:true },
  { name:'nome_pai', label:'Nome do pai', span:2, upper:true },
  { sec:'Contatos' },
  { name:'telefone', label:'Celular / WhatsApp', required:true, mask:'tel', dica:'Com DDD, ex.: (62) 99999-0000' },
  { name:'telefone2', label:'Telefone para recado', mask:'tel' },
  { name:'contato_nome', label:'Falar com (recado)' },
  { name:'email', label:'E-mail', type:'email', dica:'ex.: nome@email.com' },
  { sec:'Endereço' },
  { name:'cep', label:'CEP', mask:'cep', dica:'Preenche a rua automaticamente quando há internet.' },
  { name:'logradouro', label:'Rua, avenida…', span:2 },
  { name:'numero', label:'Número' },
  { name:'complemento', label:'Complemento' },
  { name:'bairro', label:'Bairro' },
  { name:'cidade', label:'Cidade', default:MUNICIPIO.cidade },
  { name:'uf', label:'UF', type:'select', default:MUNICIPIO.uf, options: UFS.map(u => ({ value:u, label:u })) },
  { name:'unidade_referencia_id', label:'UBS de referência', type:'select', num:true, span:4,
    options: () => S.unidades.filter(u => u.ativo && u.tipo !== 'executante').map(u => ({ value:u.id, label:u.nome })) },
];

function abrirPaciente(pac, onSalvo){
  const novo = !pac?.id, pref = uid('pac');
  modal({
    title: novo ? 'Cadastrar paciente' : 'Editar cadastro do paciente', wide:true,
    body: `<div id="${pref}-aviso"></div><p class="muted" style="margin-top:0">Campos sem a indicação "(opcional)" são obrigatórios.</p>` + formHtml(F_PACIENTE, pac || { unidade_referencia_id: S.perfil.unidade_id }, pref),
    onOpen: m => {
      const g = n => $(`#${pref}-${n}`, m);
      const nasc = g('data_nascimento'), okN = $(`#${pref}-data_nascimento-ok`, m);
      const mostraIdade = () => { const iso = brParaISO(nasc.value); okN.textContent = iso ? `${idade(iso)} anos` : ''; };
      nasc.addEventListener('input', mostraIdade); mostraIdade();
      const checar = async (campo, valida, rotulo) => {
        const el = g(campo), v = dig(el.value), ok = $(`#${pref}-${campo}-ok`, m), er = $(`#${pref}-${campo}-e`, m);
        ok.textContent = ''; er.classList.add('hidden'); el.removeAttribute('aria-invalid');
        if(!v) return;
        if(!valida(v)){ er.textContent = `${rotulo} inválido. Confira os números digitados.`; er.classList.remove('hidden'); el.setAttribute('aria-invalid','true'); return; }
        ok.textContent = '✓ válido';
        const ex = await q(sb.from('pacientes').select('*').eq(campo, v).maybeSingle());
        if(ex && ex.id !== pac?.id){
          $(`#${pref}-aviso`, m).innerHTML = alerta('warn', `Já existe paciente com este ${rotulo}: <b>${h(ex.nome)}</b>, nascido em ${fmtData(ex.data_nascimento)}, mãe ${h(ex.nome_mae || 'não informada')}.
            <div class="acoes"><button type="button" class="btn sm pri" id="${pref}-usar">Usar este cadastro</button></div>`, 'Possível cadastro duplicado');
          $(`#${pref}-usar`, m).onclick = () => { m.close(); onSalvo && onSalvo(ex); };
        }
      };
      g('cpf').addEventListener('blur', () => checar('cpf', validaCPF, 'CPF'));
      g('cns').addEventListener('blur', () => checar('cns', validaCNS, 'Cartão SUS'));
      const cep = g('cep');
      cep.addEventListener('input', async () => {
        const v = dig(cep.value); if(v.length !== 8) return;
        const ok = $(`#${pref}-cep-ok`, m); ok.textContent = 'buscando…';
        try {
          const r = await (await fetch(`https://viacep.com.br/ws/${v}/json/`)).json();
          if(r.erro){ ok.textContent = 'CEP não encontrado — preencha o endereço'; return; }
          const set = (n, val) => { if(val) g(n).value = val; };
          set('logradouro', r.logradouro); set('bairro', r.bairro); set('cidade', r.localidade); set('uf', r.uf);
          ok.textContent = '✓ endereço preenchido'; g('numero').focus();
        } catch { ok.textContent = 'sem internet — preencha o endereço'; }
      });
    },
    actions: [
      { label:'Cancelar' },
      { label: novo ? 'Salvar paciente' : 'Salvar alterações', cls:'pri', onClick: async m => {
        const d = readForm(m, F_PACIENTE, (o, err) => {
          if(!o.cns && !o.cpf) err('cpf', 'Informe o CPF ou o Cartão SUS.');
          if(o.cpf && !validaCPF(o.cpf)) err('cpf', 'CPF inválido. Confira os 11 números.');
          if(o.cns && !validaCNS(o.cns)) err('cns', 'Cartão SUS inválido. Confira os 15 números.');
          if(o.data_nascimento && (o.data_nascimento > hojeISO() || idade(o.data_nascimento) > 130)) err('data_nascimento', 'Data de nascimento fora do intervalo possível.');
          if(o.email && !/^\S+@\S+\.\S+$/.test(o.email)) err('email', 'E-mail inválido. Use o formato nome@email.com.');
        });
        const salvo = novo
          ? await q(sb.from('pacientes').insert(d).select().single())
          : await q(sb.from('pacientes').update(d).eq('id', pac.id).select().single());
        toast(novo ? 'Paciente cadastrado.' : 'Cadastro do paciente atualizado.', 'ok');
        registrarRecente(salvo);
        onSalvo && onSalvo(salvo);
      }}
    ]
  });
}

async function buscarPacientes(termo, limite=15){
  termo = safeLike(termo);
  let qb = sb.from('pacientes').select('*').order('nome').limit(limite);
  if(termo){
    const d = dig(termo);
    if(d.length >= 6 && d.length === termo.replace(/[\s.\-\/]/g,'').length) qb = qb.or(`cns.eq.${d},cpf.eq.${d}`);
    else qb = qb.ilike('nome', `%${termo}%`);
  }
  return q(qb);
}
/* dados faltando no cadastro do paciente (não bloqueia) */
function faltasPaciente(p){
  const f = [];
  if(!p.telefone) f.push('telefone'); if(!p.cns) f.push('Cartão SUS'); if(!p.cpf) f.push('CPF');
  if(!p.logradouro) f.push('endereço'); if(!p.nome_mae) f.push('nome da mãe');
  return f;
}

/* Ficha do paciente: dados agrupados + histórico */
async function fichaPaciente(pacId, aba='dados'){
  registrarAcesso(pacId, 'ficha do paciente');
  const p = await q(sb.from('pacientes').select('*').eq('id', pacId).single());
  const lst = await q(sb.from('vw_solicitacoes').select('*').eq('paciente_id', pacId).order('created_at', { ascending:false }));
  registrarRecente(p);
  const end = [p.logradouro, p.numero, p.complemento, p.bairro, [p.cidade, p.uf].filter(Boolean).join('/'), p.cep ? 'CEP ' + fCEP(p.cep) : ''].filter(Boolean).join(', ');
  const faltas = faltasPaciente(p);
  const m = modal({ title:`Ficha do paciente`, wide:true,
    body:`<div class="pac-card" style="margin-bottom:14px"><div><div class="nome">${h(p.nome)}${p.nome_social ? ` <span class="muted">(${h(p.nome_social)})</span>` : ''}</div>
        <div class="muted">${fmtData(p.data_nascimento)} · ${idade(p.data_nascimento)} anos · ${{F:'Feminino',M:'Masculino',I:'Sexo não informado'}[p.sexo]}</div></div>
        <div class="acoes">${pode('solicitacao') ? `<a class="btn sm pri" href="#/solicitacao?pac=${p.id}" data-fecha>Nova solicitação</a>` : ''}</div></div>
      ${faltas.length ? alerta('warn', `Cadastro sem: ${faltas.join(', ')}.`, 'Cadastro incompleto') : ''}
      <div class="tabs" role="tablist">
        <button role="tab" id="tab-d" aria-controls="pn-d" aria-selected="${aba==='dados'}">Dados</button>
        <button role="tab" id="tab-h" aria-controls="pn-h" aria-selected="${aba!=='dados'}">Histórico (${lst.length})</button></div>
      <div role="tabpanel" id="pn-d" aria-labelledby="tab-d" ${aba!=='dados'?'hidden':''}>
        <h3 class="secao-t">Identificação</h3>
        <dl class="dl"><div><dt>CPF</dt><dd>${fCPF(p.cpf)}</dd></div><div><dt>Cartão SUS</dt><dd>${fCNS(p.cns)}</dd></div>
          <div><dt>Nome da mãe</dt><dd>${h(p.nome_mae || '—')}</dd></div><div><dt>Nome do pai</dt><dd>${h(p.nome_pai || '—')}</dd></div></dl>
        <h3 class="secao-t">Contatos</h3>
        <dl class="dl"><div><dt>Celular</dt><dd>${fTel(p.telefone)}</dd></div><div><dt>Recado</dt><dd>${fTel(p.telefone2)}${p.contato_nome ? ' — ' + h(p.contato_nome) : ''}</dd></div>
          <div><dt>E-mail</dt><dd>${h(p.email || '—')}</dd></div></dl>
        <h3 class="secao-t">Endereço e referência</h3>
        <dl class="dl"><div style="grid-column:1/-1"><dt>Endereço</dt><dd>${h(end || '—')}</dd></div><div><dt>UBS de referência</dt><dd>${h(p.unidade_referencia_id ? nomeUnidade(p.unidade_referencia_id) : '—')}</dd></div></dl>
      </div>
      <div role="tabpanel" id="pn-h" aria-labelledby="tab-h" ${aba==='dados'?'hidden':''}>
        ${lst.length ? `<div class="tbl-wrap"><table class="resp"><thead><tr><th>Protocolo</th><th>Procedimento</th><th>Situação</th><th>Agendamento</th></tr></thead><tbody>
          ${lst.map(s => `<tr class="clicavel" tabindex="0" data-id="${s.id}"><td data-label="Protocolo"><b>${h(s.protocolo)}</b><small>${fmtData(s.created_at)}</small></td>
            <td data-label="Procedimento">${h(s.procedimento_nome)}</td><td data-label="Situação">${badgeSt(s)}</td>
            <td data-label="Agendamento">${s.vaga_data ? `${fmtData(s.vaga_data)} ${fmtHora(s.vaga_hora)}<small>${h(s.unidade_executante_nome)} · guia ${h(s.numero_guia)}</small>` : '—'}</td></tr>`).join('')}</tbody></table></div>`
          : estado({ titulo:'Nenhuma solicitação para este paciente' })}
      </div>`,
    actions:[ ...(pode('pacientes') || pode('solicitacao') ? [{ label:'Editar cadastro', onClick: () => { abrirPaciente(p, () => fichaPaciente(p.id)); } }] : []), { label:'Fechar', cls:'pri' }] });
  const tabs = $$('[role=tab]', m);
  tabs.forEach(t => t.onclick = () => { tabs.forEach(x => { x.setAttribute('aria-selected', x === t); $('#' + x.getAttribute('aria-controls'), m).hidden = x !== t; }); });
  $$('tr[data-id]', m).forEach(tr => { const go = () => { m.close(); abrirSolicitacao(+tr.dataset.id); }; tr.onclick = go; tr.onkeydown = e => { if(e.key === 'Enter') go(); }; });
  $$('[data-fecha]', m).forEach(a => a.addEventListener('click', () => m.close()));
}

/* =====================================================================
   NOVA SOLICITAÇÃO — assistente em 5 etapas
   1 Paciente · 2 Pedido médico · 3 Procedimentos · 4 Risco e justificativa · 5 Revisão
   Cada procedimento gera uma solicitação (regra mantida).
   ===================================================================== */
const ETAPAS = ['Paciente', 'Pedido médico', 'Procedimentos', 'Risco e justificativa', 'Revisão'];
const chaveRascunho = () => 'regula_rascunho_' + S.perfil.id;

async function pgSolicitacao(el){
  if(papel() === 'solicitante' && !S.perfil.unidade_id){
    el.innerHTML = estado({ tipo:'permissao', titulo:'Usuário sem unidade', texto:'Para registrar solicitações, seu usuário precisa estar vinculado a uma unidade. Peça ao administrador para fazer o vínculo em Usuários.' });
    return;
  }
  const novoW = () => ({ etapa:1, max:1, pac:null, origem:S.perfil.unidade_id || '', data_pedido:fmtData(hojeISO()), profissional:'', crm:'', cid10:'',
    registro:'', itens:[], prioridade:'azul', justificativa:'' });
  let W = novoW(), abertas = [];
  const rasc = store.get(chaveRascunho());
  const pid = params().get('pac');

  const salvarRascunho = debounce(() => {
    if(W.pac || W.itens.length || W.profissional) store.set(chaveRascunho(), { W, em:new Date().toISOString() });
  }, 400);
  const excluirRascunho = () => store.del(chaveRascunho());

  el.innerHTML = `<div id="sw-rasc"></div><div class="card"><ol class="etapas" id="sw-etapas" aria-label="Etapas da solicitação"></ol><div id="sw-corpo"></div></div>`;

  const mostrarRascunho = () => {
    const r = store.get(chaveRascunho());
    if(!r || W._retomado) { $('#sw-rasc').innerHTML = ''; return; }
    $('#sw-rasc').innerHTML = alerta('info', `Você tem uma solicitação não concluída${r.W.pac ? ` de <b>${h(r.W.pac.nome)}</b>` : ''}, salva em ${fmtDataHora(r.em)}. Ela é só um <b>rascunho</b>: ainda não foi registrada.
      <div class="acoes"><button class="btn sm pri" id="r-ret">Retomar rascunho</button><button class="btn sm err-sec" id="r-exc">Excluir rascunho</button></div>`, 'Rascunho salvo');
    $('#r-ret').onclick = () => { W = { ...novoW(), ...r.W, _retomado:true }; $('#sw-rasc').innerHTML = ''; render(); };
    $('#r-exc').onclick = async () => {
      const c = await confirmar({ titulo:'Excluir rascunho', botao:'Excluir rascunho', cls:'err', html:'<p>O rascunho será apagado. Nenhuma solicitação registrada é afetada.</p>' });
      if(c.ok){ excluirRascunho(); $('#sw-rasc').innerHTML = ''; toast('Rascunho excluído.', 'ok'); }
    };
  };

  const irEtapa = n => { W.etapa = n; W.max = Math.max(W.max, n); render(); salvarRascunho(); $('#sw-titulo')?.focus(); };

  function render(){
    $('#sw-etapas').innerHTML = ETAPAS.map((t, i) => { const n = i + 1, st = n === W.etapa ? 'atual' : (n < W.etapa || n <= W.max) ? 'feita' : '';
      return `<li class="${st}"><button type="button" data-et="${n}" ${n > W.max ? 'disabled' : ''} ${n === W.etapa ? 'aria-current="step"' : ''}>
        <span class="n">${n < W.etapa ? '✓' : n}</span><span class="rot">${h(t)}</span></button></li>`; }).join('');
    $$('[data-et]', el).forEach(b => b.onclick = () => irEtapa(+b.dataset.et));
    const corpo = $('#sw-corpo');
    corpo.innerHTML = `<h2 id="sw-titulo" tabindex="-1" style="font-size:18px">Etapa ${W.etapa} de 5 — ${h(ETAPAS[W.etapa-1])}</h2><div id="sw-erros"></div>` + [, etapa1, etapa2, etapa3, etapa4, etapa5][W.etapa]()
      + `<div class="acoes" style="margin-top:20px;border-top:1px solid var(--borda);padding-top:14px">
          ${W.etapa > 1 ? `<button type="button" class="btn" id="sw-voltar">‹ Voltar</button>` : ''}
          <span class="spacer"></span>
          ${W.etapa < 5 ? `<button type="button" class="btn pri lg" id="sw-prox">Continuar ›</button>` : `<button type="button" class="btn ok lg" id="sw-reg">Registrar solicitação</button>`}</div>`;
    [, liga1, liga2, liga3, liga4, liga5][W.etapa](corpo);
    const v = $('#sw-voltar'); if(v) v.onclick = () => { coletar(corpo); irEtapa(W.etapa - 1); };
    const p = $('#sw-prox'); if(p) p.onclick = () => { try { validar(corpo); irEtapa(W.etapa + 1); } catch(e){ if(!(e instanceof ErroForm)) toast(e.message, 'err'); } };
    const r = $('#sw-reg'); if(r) r.onclick = () => ocupado(r, registrar);
  }

  /* ---------- Etapa 1: paciente ---------- */
  function etapa1(){
    if(W.pac){
      const p = W.pac, f = faltasPaciente(p);
      return `<div class="pac-card"><div><div class="nome">${h(p.nome)}${p.nome_social ? ` <span class="muted">(${h(p.nome_social)})</span>` : ''}</div>
          <div class="muted">${fmtData(p.data_nascimento)} · ${idade(p.data_nascimento)} anos · CPF ${fCPF(p.cpf)} · CNS ${fCNS(p.cns)}</div>
          <div class="muted">Celular ${fTel(p.telefone)} · Mãe: ${h(p.nome_mae || 'não informada')}</div></div>
          <div class="acoes"><button type="button" class="btn sm" id="p-edit">Editar cadastro</button><button type="button" class="btn sm" id="p-troca">Trocar paciente</button></div></div>
        ${f.length ? alerta('warn', `Faltam no cadastro: <b>${f.join(', ')}</b>. Não impede a solicitação, mas dificulta o contato e a regulação. <button type="button" class="btn sm link" id="p-comp">Completar cadastro</button>`) : ''}
        <div id="p-abertas" style="margin-top:12px"></div>`;
    }
    return `<div class="field" style="max-width:680px">
        <label for="busca-pac">Buscar paciente</label>
        <span class="dica" id="busca-pac-d">Digite nome, CPF ou Cartão SUS (mínimo 3 caracteres).</span>
        <p class="erro-msg hidden" id="busca-pac-e"></p>
        <input type="search" id="busca-pac" aria-describedby="busca-pac-d busca-pac-e" autocomplete="off">
      </div>
      <div id="pac-res" aria-live="polite"></div>
      <p style="margin-top:14px">Não encontrou? <button type="button" class="btn" id="btn-novo-pac">+ Cadastrar novo paciente</button></p>`;
  }
  function liga1(c){
    const sel = p => { W.pac = p; registrarRecente(p); salvarRascunho(); render(); };
    if(W.pac){
      $('#p-troca', c).onclick = () => { W.pac = null; render(); $('#busca-pac')?.focus(); };
      const ed = () => abrirPaciente(W.pac, p => sel(p));
      $('#p-edit', c).onclick = ed; const cp = $('#p-comp', c); if(cp) cp.onclick = ed;
      q(sb.from('vw_solicitacoes').select('*').eq('paciente_id', W.pac.id).in('status', ABERTAS).order('created_at')).then(l => {
        abertas = l; const box = $('#p-abertas'); if(!box) return;
        box.innerHTML = l.length ? `<h3 class="secao-t">Solicitações em aberto deste paciente</h3><ul class="lista-alertas">${l.map(s => `<li><span style="flex:1"><b>${h(s.procedimento_nome)}</b>
          <span class="sub-linha">Protocolo ${h(s.protocolo)} · ${fmtData(s.created_at)}${s.vaga_data ? ` · agendado ${fmtData(s.vaga_data)}` : ''}</span></span>${badgeSt(s)}</li>`).join('')}</ul>` : '';
      });
      return;
    }
    const inp = $('#busca-pac', c), res = $('#pac-res', c);
    inp.oninput = debounce(async () => {
      const t = inp.value.trim();
      if(t.length < 3){ res.innerHTML = ''; return; }
      res.innerHTML = carregando('Buscando…', true);
      const lst = await buscarPacientes(t, 10);
      res.innerHTML = lst.length ? `<p class="muted" style="margin:8px 0 0">${lst.length} paciente(s) encontrado(s). Confira data de nascimento e nome da mãe antes de selecionar.</p>
        <div class="resultado-busca">${lst.map(p => `<button type="button" class="item" data-id="${p.id}"><span><b>${h(p.nome)}</b>
          <span class="sub-linha">Nasc. ${fmtData(p.data_nascimento)} · CPF ${cpfOculto(p.cpf)} · CNS ${cnsOculto(p.cns)} · Mãe: ${h(p.nome_mae || '—')}</span></span><span class="btn sm" aria-hidden="true">Selecionar</span></button>`).join('')}</div>`
        : alerta('warn', `Nenhum paciente encontrado para "<b>${h(t)}</b>". <button type="button" class="btn sm link" id="cad-busca">Cadastrar novo paciente</button>`);
      $$('.item', res).forEach(b => b.onclick = () => sel(lst.find(p => p.id == b.dataset.id)));
      const cb = $('#cad-busca', res); if(cb) cb.onclick = () => novoPac(t);
    });
    const novoPac = (termo='') => {
      const d = dig(termo), pre = { unidade_referencia_id:S.perfil.unidade_id };
      if(d.length === 11) pre.cpf = d; else if(d.length === 15) pre.cns = d; else if(termo && !d) pre.nome = termo.toUpperCase();
      abrirPaciente(pre, sel);
    };
    $('#btn-novo-pac', c).onclick = () => novoPac(inp.value.trim());
    inp.focus();
  }

  /* ---------- Etapa 2: pedido médico ---------- */
  const F_PEDIDO = () => [
    { name:'origem', label:'Unidade ou serviço que emitiu o pedido', type:'select', required:true, num:true, span:2,
      options: S.unidades.filter(u => u.ativo).map(u => ({ value:u.id, label:u.nome })), dica:'Onde o médico atendeu o paciente.' },
    { name:'data_pedido', label:'Data do pedido médico', required:true, mask:'data', dica:'dd/mm/aaaa, como está no pedido' },
    { name:'cid10', label:'CID-10', dica:'Ex.: I10 ou M54.5', attrs:'maxlength="6" style="text-transform:uppercase"' },
    { name:'profissional', label:'Profissional solicitante', required:true, span:2, dica:'Nome do médico(a) que assinou o pedido' },
    { name:'crm', label:'CRM ou registro', dica:'Ex.: CRM-GO 12345' },
    ...(!S.perfil.unidade_id ? [{ name:'registro', label:'Unidade de registro', type:'select', required:true, num:true,
      options: S.unidades.filter(u => u.ativo && u.tipo !== 'executante').map(u => ({ value:u.id, label:u.nome })), dica:'Unidade onde a solicitação está sendo registrada.' }] : []),
  ];
  function etapa2(){ return formHtml(F_PEDIDO(), { origem:W.origem, data_pedido:W.data_pedido, cid10:W.cid10, profissional:W.profissional, crm:W.crm, registro:W.registro }, 'sw'); }
  function liga2(c){ $$('input,select', c).forEach(i => i.addEventListener('change', () => { coletar(c); salvarRascunho(); })); }

  /* ---------- Etapa 3: procedimentos ---------- */
  function etapa3(){
    const procs = S.procedimentos.filter(p => p.ativo);
    const grupos = Object.keys(TIPOS_PROC).map(t => [t, procs.filter(p => p.tipo === t)]).filter(g => g[1].length);
    return `<p class="muted" style="margin-top:0">Um pedido pode ter vários exames ou consultas. <b>Cada procedimento gera uma solicitação</b>, com protocolo próprio.</p>
      <div class="field" style="max-width:680px"><label for="sel-proc">Procedimento</label>
        <span class="dica" id="sel-proc-d">Escolha e clique em Adicionar. Repita para cada item do pedido.</span>
        <p class="erro-msg hidden" id="sel-proc-e"></p>
        <div class="row" style="flex-wrap:nowrap"><select id="sel-proc" aria-describedby="sel-proc-d sel-proc-e" style="flex:1"><option value="">Selecione</option>
          ${grupos.map(([t, l]) => `<optgroup label="${h(TIPOS_PROC[t])}">${l.map(p => `<option value="${p.id}">${p.codigo_sigtap ? h(p.codigo_sigtap) + ' — ' : ''}${h(p.nome)}${p.exige_regulacao ? ' — exige regulação' : ''}</option>`).join('')}</optgroup>`).join('')}
        </select><button type="button" class="btn" id="add-proc">+ Adicionar</button></div></div>
      <div class="proc-list" id="proc-list" aria-live="polite"></div>`;
  }
  function liga3(c){
    const lista = () => {
      $('#proc-list', c).innerHTML = W.itens.length ? `<h3 class="secao-t">${W.itens.length} procedimento(s) no pedido</h3>` + W.itens.map((id, i) => {
        const dup = abertas.filter(s => s.procedimento_id === id);
        return `<div class="pi"><span><b>${h(nomeProc(id))}</b> ${procExige(id) ? tagReg() : ''}
          ${dup.length ? `<span class="sub-linha" style="color:var(--warn)">⚠ Já existe solicitação em aberto: protocolo ${h(dup[0].protocolo)} (${h(rotuloStatus(dup[0]))}). Registre de novo só se for um pedido novo.</span>` : ''}</span>
          <button type="button" class="btn sm err-sec" data-rm="${i}" aria-label="Remover ${h(nomeProc(id))}">Remover</button></div>`; }).join('')
        : '<p class="muted">Nenhum procedimento adicionado ainda.</p>';
      $$('[data-rm]', c).forEach(b => b.onclick = () => { const n = nomeProc(W.itens[+b.dataset.rm]); W.itens.splice(+b.dataset.rm, 1); lista(); salvarRascunho(); toast(`${n} removido.`); $('#sel-proc', c).focus(); });
    };
    const add = () => {
      const s = $('#sel-proc', c), v = +s.value, e = $('#sel-proc-e', c);
      e.classList.add('hidden'); s.removeAttribute('aria-invalid');
      if(!v){ e.textContent = 'Escolha um procedimento na lista.'; e.classList.remove('hidden'); s.setAttribute('aria-invalid','true'); s.focus(); return; }
      if(W.itens.includes(v)){ e.textContent = 'Este procedimento já está no pedido.'; e.classList.remove('hidden'); s.focus(); return; }
      W.itens.push(v); s.value = ''; lista(); salvarRascunho(); s.focus();
    };
    $('#add-proc', c).onclick = add;
    $('#sel-proc', c).onkeydown = e => { if(e.key === 'Enter'){ e.preventDefault(); add(); } };
    if(W.pac && !abertas.length) q(sb.from('vw_solicitacoes').select('*').eq('paciente_id', W.pac.id).in('status', ABERTAS)).then(l => { abertas = l; lista(); });
    lista();
  }

  /* ---------- Etapa 4: risco e justificativa ---------- */
  const exigeJust = () => W.itens.some(procExige);
  function etapa4(){
    const crit = Object.entries(CRITERIOS_RISCO).some(([, l]) => l.length);
    return `<fieldset style="border:0;padding:0;margin:0"><legend style="font-weight:700;margin-bottom:6px">Classificação de risco sugerida pelo solicitante</legend>
        <p class="muted" style="margin-top:0">O regulador pode reclassificar. Use o protocolo de regulação do município.</p>
        <div class="prio-opts">${Object.entries(PRIORIDADES).map(([k, p]) => `<label><input type="radio" name="prioridade" value="${k}" ${W.prioridade===k?'checked':''}>
          <span><b><span aria-hidden="true" style="color:${p.c}">${p.s}</span> ${p.l}</b><small>${h(p.d)}</small></span></label>`).join('')}</div>
        <details class="criterios"><summary>Critérios do protocolo local</summary>
          ${crit ? Object.entries(CRITERIOS_RISCO).map(([k, l]) => l.length ? `<p><b>${PRIORIDADES[k].l}:</b></p><ul>${l.map(x => `<li>${h(x)}</li>`).join('')}</ul>` : '').join('')
            : '<p>Nenhum protocolo local cadastrado. O sistema não define critérios clínicos: a regulação municipal deve configurá-los (variável <code>CRITERIOS_RISCO</code>).</p>'}
        </details></fieldset>
      <div class="field" style="margin-top:18px">
        <label for="sw-justificativa">Justificativa clínica ${exigeJust() ? '' : '<span class="opc">(opcional)</span>'}</label>
        <span class="dica" id="sw-justificativa-d">${exigeJust() ? '<b>Obrigatória</b>: há procedimento que exige regulação. Escreva pelo menos 20 caracteres com' : 'Recomendada:'} história, exame físico, exames anteriores e hipótese diagnóstica, conforme o pedido.</span>
        <p class="erro-msg hidden" id="sw-justificativa-e"></p>
        <textarea id="sw-justificativa" name="justificativa" rows="6" aria-describedby="sw-justificativa-d sw-justificativa-e">${h(W.justificativa)}</textarea>
        <span class="dica" id="sw-cont" aria-live="polite"></span></div>`;
  }
  function liga4(c){
    const t = $('#sw-justificativa', c), ct = $('#sw-cont', c);
    const conta = () => { ct.textContent = `${t.value.trim().length} caracteres`; };
    t.oninput = () => { conta(); coletar(c); salvarRascunho(); }; conta();
    $$('input[name=prioridade]', c).forEach(r => r.onchange = () => { coletar(c); salvarRascunho(); });
  }

  /* ---------- Etapa 5: revisão ---------- */
  function etapa5(){
    const p = W.pac, reg = W.itens.filter(procExige).length;
    const sec = (n, t, html) => `<section><h3>${h(t)} <button type="button" class="btn sm link" data-alt="${n}">Alterar<span class="sr-only"> ${h(t)}</span></button></h3>${html}</section>`;
    return `<p>Confira os dados antes de registrar. Nada foi gravado ainda.</p>
      <div class="revisao">
        ${sec(1, 'Paciente', `<dl class="dl"><div><dt>Nome</dt><dd>${h(p.nome)}</dd></div><div><dt>Nascimento</dt><dd>${fmtData(p.data_nascimento)} (${idade(p.data_nascimento)} anos)</dd></div>
          <div><dt>CPF</dt><dd>${fCPF(p.cpf)}</dd></div><div><dt>Cartão SUS</dt><dd>${fCNS(p.cns)}</dd></div><div><dt>Celular</dt><dd>${fTel(p.telefone)}</dd></div></dl>`)}
        ${sec(2, 'Pedido médico', `<dl class="dl"><div><dt>Emitido por</dt><dd>${h(nomeUnidade(+W.origem))}</dd></div><div><dt>Data do pedido</dt><dd>${h(W.data_pedido)}</dd></div>
          <div><dt>Profissional</dt><dd>${h(W.profissional)}${W.crm ? ' — ' + h(W.crm) : ''}</dd></div><div><dt>CID-10</dt><dd>${h(W.cid10 || '—')}</dd></div></dl>`)}
        ${sec(3, `Procedimentos (${W.itens.length})`, `<ul style="margin:0;padding-left:20px">${W.itens.map(id => `<li>${h(nomeProc(id))} ${procExige(id) ? '— vai para <b>análise regulatória</b>' : '— vai direto para o <b>agendamento</b>'}</li>`).join('')}</ul>`)}
        ${sec(4, 'Risco e justificativa', `<p>${badgePrio(W.prioridade, true)}</p>${W.justificativa ? `<div class="box">${h(W.justificativa)}</div>` : '<p class="muted">Sem justificativa.</p>'}`)}
      </div>
      ${alerta('info', `Serão criadas <b>${W.itens.length}</b> solicitação(ões), uma por procedimento.${reg ? ` <b>${reg}</b> precisa(m) de análise do regulador antes do agendamento.` : ''}`)}`;
  }
  function liga5(c){ $$('[data-alt]', c).forEach(b => b.onclick = () => irEtapa(+b.dataset.alt)); }

  /* ---------- coleta e validação ---------- */
  function coletar(c){
    if(W.etapa === 2){ const g = n => $(`#sw-${n}`, c); if(!g('origem')) return;
      W.origem = g('origem').value; W.data_pedido = g('data_pedido').value; W.cid10 = g('cid10').value.trim().toUpperCase();
      W.profissional = g('profissional').value.trim(); W.crm = g('crm').value.trim(); if(g('registro')) W.registro = g('registro').value; }
    if(W.etapa === 4){ const r = $('input[name=prioridade]:checked', c); if(r) W.prioridade = r.value; const t = $('#sw-justificativa', c); if(t) W.justificativa = t.value.trim(); }
  }
  function validar(c){
    coletar(c);
    const box = $('#sw-erros', c);
    if(W.etapa === 1){
      if(!W.pac){ mostrarErros(c, [{ id:'busca-pac', msg:'Selecione um paciente da lista ou cadastre um novo.' }], box); throw new ErroForm([]); }
    }
    if(W.etapa === 2){
      readForm(c, F_PEDIDO(), (o, err) => {
        if(o.data_pedido && o.data_pedido > hojeISO()) err('data_pedido', 'A data do pedido não pode ser no futuro.');
        const cid = (o.cid10 || '').toUpperCase().replace('.', '');
        if(cid && !/^[A-Z]\d{2}\d?$/.test(cid)) err('cid10', 'CID-10 inválido. Use letra + 2 ou 3 números, ex.: I10 ou M545.');
      }, box);
    }
    if(W.etapa === 3 && !W.itens.length){ mostrarErros(c, [{ id:'sel-proc', msg:'Adicione pelo menos um procedimento.' }], box); throw new ErroForm([]); }
    if(W.etapa === 4 && exigeJust() && W.justificativa.length < 20){
      mostrarErros(c, [{ id:'sw-justificativa', msg:'Escreva a justificativa clínica com pelo menos 20 caracteres (obrigatória para procedimento com regulação).' }], box); throw new ErroForm([]);
    }
  }

  /* ---------- registro ---------- */
  async function registrar(){
    const unidReg = S.perfil.unidade_id || +W.registro;
    if(!unidReg){ irEtapa(2); return; }
    const base = { paciente_id:W.pac.id, unidade_solicitante_id:unidReg, unidade_origem_id:+W.origem || null,
      profissional_solicitante:W.profissional, crm_solicitante:W.crm || null, data_pedido:brParaISO(W.data_pedido),
      cid10:(W.cid10 || '').replace('.', '') || null, prioridade:W.prioridade, justificativa:W.justificativa || null };
    try {
      const criadas = await q(sb.from('solicitacoes').insert(W.itens.map(pid => ({ ...base, procedimento_id:pid }))).select('id,protocolo,procedimento_id'));
      excluirRascunho(); atualizarContadores();
      const pac = W.pac, agendaveis = criadas.filter(c => !procExige(c.procedimento_id));
      el.innerHTML = `<section class="card" aria-labelledby="ok-t">
        ${alerta('ok', `Solicitação de <b>${h(pac.nome)}</b> registrada em ${fmtDataHora(new Date())}.`, 'Registro concluído')}
        <h2 id="ok-t" tabindex="-1" style="font-size:18px">Protocolos gerados</h2>
        <div class="tbl-wrap"><table class="resp"><thead><tr><th>Protocolo</th><th>Procedimento</th><th>Próximo passo</th></tr></thead><tbody>
          ${criadas.map(c => `<tr><td data-label="Protocolo"><b>${h(c.protocolo)}</b></td><td data-label="Procedimento">${h(nomeProc(c.procedimento_id))}</td>
            <td data-label="Próximo passo">${procExige(c.procedimento_id) ? `${badgeSt('regulacao')} <span class="sub-linha">O regulador vai analisar; a unidade acompanha em Solicitações.</span>` : `${badgeSt('pendente')} <span class="sub-linha">Pode ser agendado agora.</span>`}</td></tr>`).join('')}
        </tbody></table></div>
        <p class="muted" style="margin-top:10px">Informe os números de protocolo ao paciente para acompanhamento.</p>
        <div class="acoes" style="margin-top:12px">
          ${agendaveis.length && pode('agendamento') ? `<a class="btn pri lg" href="#/agendamento?pac=${pac.id}">Agendar agora ›</a>` : ''}
          <a class="btn" href="#/solicitacao?pac=${pac.id}&n=${Date.now()}">Nova solicitação para ${h(pac.nome.split(' ')[0])}</a>
          <a class="btn" href="#/solicitacao?n=${Date.now()}">Nova solicitação (outro paciente)</a>
          <a class="btn link" href="#/solicitacoes">Ver solicitações</a></div></section>`;
      $('#ok-t', el).focus();
    } catch(e){
      $('#sw-erros').innerHTML = alerta('err', h(e.message) + ' Seus dados continuam preenchidos; tente de novo.', 'Não foi possível registrar');
      $('#sw-erros').scrollIntoView({ block:'center' });
    }
  }

  if(pid){
    const p = await q(sb.from('pacientes').select('*').eq('id', pid).maybeSingle());
    if(p){ W.pac = p; registrarRecente(p); W.etapa = 2; W.max = 2; }
  }
  mostrarRascunho();
  render();
}

/* =====================================================================
   FILTROS COMPARTILHADOS (Solicitações, Fila de espera, Análise regulatória)
   ===================================================================== */
const FILTRO_STATUS = [
  ['', 'Todas as situações'], ['abertas', 'Em aberto (qualquer etapa)'], ['regulacao', 'Aguardando regulação'], ['pendente', 'Pendentes (com e sem regulação obrigatória)'], ['agendar', 'Aguardando agendamento'],
  ['autorizada', 'Autorizadas — aguardando vaga'], ['devolvida', 'Devolvidas à unidade'], ['negada', 'Negadas'], ['agendada', 'Agendadas'],
  ['realizada', 'Realizadas'], ['faltou', 'Faltas'], ['cancelada', 'Canceladas'],
];
const ORDENS = [['prioridade', 'Prioridade (risco) e mais antigas'], ['espera', 'Maior tempo de espera'], ['pedido', 'Data do pedido (mais antigo)'], ['recentes', 'Registradas mais recentemente']];
function casaStatus(s, f){
  switch(f){
    case '': return true;
    case 'abertas': return ABERTAS.includes(s.status);
    case 'regulacao': return s.status === 'pendente' && s.exige_regulacao;
    case 'agendar': return s.status === 'autorizada' || (s.status === 'pendente' && !s.exige_regulacao);
    case 'reagendar': return s.status === 'faltou';
    case 'pendente': return s.status === 'pendente';
    default: return s.status === f;
  }
}
function filtrosHtml(pref, v={}, { status=FILTRO_STATUS.map(x => x[0]), ordem=true, periodo=true } = {}){
  const id = n => `${pref}-${n}`;
  return `<form class="filtros recolhivel no-print" id="${id('form')}" role="search" aria-label="Filtros">
    <div class="field cresce"><label for="${id('txt')}">Buscar</label><input type="search" id="${id('txt')}" value="${h(v.txt||'')}" placeholder="Nome, CPF, Cartão SUS, protocolo ou procedimento"></div>
    <button type="button" class="btn sm filtros-toggle" aria-expanded="false" data-acao="alternar-filtros">Mais filtros</button>
    <div class="field"><label for="${id('st')}">Situação</label><select id="${id('st')}">${FILTRO_STATUS.filter(x => status.includes(x[0])).map(([k, l]) => `<option value="${k}" ${k===(v.st??'')?'selected':''}>${h(l)}</option>`).join('')}</select></div>
    <div class="field"><label for="${id('pr')}">Risco</label><select id="${id('pr')}"><option value="">Todos</option>${Object.entries(PRIORIDADES).map(([k, p]) => `<option value="${k}" ${k===v.pr?'selected':''}>${p.s} ${p.l}</option>`).join('')}</select></div>
    <div class="field"><label for="${id('proc')}">Procedimento</label><select id="${id('proc')}">${optList(S.procedimentos, v.proc, 'Todos')}</select></div>
    <div class="field"><label for="${id('orig')}">Origem do pedido</label><select id="${id('orig')}">${optList(S.unidades.filter(u => u.tipo !== 'executante'), v.orig, 'Todas')}</select></div>
    ${periodo ? `<div class="field"><label for="${id('de')}">Registrada de</label><input type="date" id="${id('de')}" value="${h(v.de||'')}"></div>
    <div class="field"><label for="${id('ate')}">até</label><input type="date" id="${id('ate')}" value="${h(v.ate||'')}"></div>` : ''}
    ${ordem ? `<div class="field"><label for="${id('ord')}">Ordenar por</label><select id="${id('ord')}">${ORDENS.map(([k, l]) => `<option value="${k}" ${k===(v.ord||'prioridade')?'selected':''}>${h(l)}</option>`).join('')}</select></div>` : ''}
    <button type="button" class="btn link" id="${id('limpar')}">Limpar filtros</button>
  </form>`;
}
function lerFiltros(pref){
  const g = n => document.getElementById(`${pref}-${n}`)?.value ?? '';
  return { txt:g('txt').trim(), st:g('st'), pr:g('pr'), proc:g('proc'), orig:g('orig'), de:g('de'), ate:g('ate'), ord:g('ord') || 'prioridade' };
}
function ligarFiltros(pref, fn, padrao={}){
  const f = document.getElementById(`${pref}-form`);
  f.onsubmit = e => e.preventDefault();
  $$('select,input[type=date]', f).forEach(i => i.onchange = fn);
  document.getElementById(`${pref}-txt`).oninput = debounce(fn, 300);
  document.getElementById(`${pref}-limpar`).onclick = () => {
    $$('select', f).forEach(s => s.value = padrao[s.id.replace(pref + '-', '')] ?? s.options[0].value);
    $$('input', f).forEach(i => i.value = padrao[i.id.replace(pref + '-', '')] ?? ''); fn();
  };
}
function aplicarFiltros(rows, f){
  const t = f.txt.toLowerCase(), d = dig(f.txt);
  let l = rows.filter(s => casaStatus(s, f.st)
    && (!f.pr || s.prioridade === f.pr) && (!f.proc || s.procedimento_id == f.proc) && (!f.orig || s.unidade_origem_id == f.orig)
    && (!f.de || s.created_at.slice(0,10) >= f.de) && (!f.ate || s.created_at.slice(0,10) <= f.ate)
    && (!t || (s.paciente_nome || '').toLowerCase().includes(t) || (s.procedimento_nome || '').toLowerCase().includes(t) || s.protocolo.includes(t)
        || (d.length >= 6 && (s.paciente_cpf === d || s.paciente_cns === d)) || (s.numero_guia && d && s.numero_guia === d)));
  const cmp = {
    prioridade:(a, b) => a.peso_prioridade - b.peso_prioridade || a.created_at.localeCompare(b.created_at),
    espera:(a, b) => b.dias_espera - a.dias_espera || a.peso_prioridade - b.peso_prioridade,
    pedido:(a, b) => String(a.data_pedido || a.created_at).localeCompare(String(b.data_pedido || b.created_at)),
    recentes:(a, b) => b.created_at.localeCompare(a.created_at),
  }[f.ord] || (() => 0);
  return l.sort(cmp);
}
const resumoFiltro = (f, n) => {
  const p = [];
  if(f.st) p.push(FILTRO_STATUS.find(x => x[0] === f.st)?.[1]); if(f.pr) p.push('risco ' + PRIORIDADES[f.pr].l);
  if(f.proc) p.push(nomeProc(+f.proc)); if(f.orig) p.push('origem ' + nomeUnidade(+f.orig));
  if(f.de || f.ate) p.push(`registradas ${f.de ? 'de ' + fmtData(f.de) : ''} ${f.ate ? 'até ' + fmtData(f.ate) : ''}`.trim()); if(f.txt) p.push(`busca "${f.txt}"`);
  return `<p class="muted" aria-live="polite" style="margin:0 0 8px"><b>${num(n)}</b> solicitação(ões)${p.length ? ' · ' + h(p.join(' · ')) : ''}</p>`;
};

/* colunas padrão de uma lista de solicitações */
const COLS_SOL = {
  protocolo:{ l:'Protocolo', f:s => `<b>${h(s.protocolo)}</b><small>registrada ${fmtData(s.created_at)}</small>`, v:s => s.protocolo },
  paciente:{ l:'Paciente', f:s => `${h(s.paciente_nome)}<small>${idade(s.paciente_nascimento)} anos · CPF ${cpfOculto(s.paciente_cpf)}</small>`, v:s => s.paciente_nome },
  procedimento:{ l:'Procedimento', f:s => `${h(s.procedimento_nome)} ${s.exige_regulacao ? tagReg() : ''}`, v:s => s.procedimento_nome },
  origem:{ l:'Origem', f:s => `${h(s.unidade_origem_nome || s.unidade_solicitante_nome)}<small>pedido ${fmtData(s.data_pedido)}</small>`, v:s => s.unidade_origem_nome },
  risco:{ l:'Risco', f:s => badgePrio(s.prioridade), v:s => s.peso_prioridade },
  /* Duas medidas na mesma coluna. A de cima é a que ordena a fila, contada
     do lançamento no sistema; a de baixo é a espera real do paciente, do
     pedido médico. Mostrar só uma esconde o tempo que o paciente esperou e
     a fila não conta — era exatamente o que acontecia nesta tela. */
  espera:{ l:'Espera', n:1, v:s => s.dias_espera,
    f:s => `${num(s.dias_espera)} dia(s)` + (
      s.dias_desde_pedido != null && s.dias_desde_pedido !== s.dias_espera
        ? `<small${s.dias_ate_insercao >= 7 ? ' class="atraso"' : ''}>${num(s.dias_desde_pedido)} desde o pedido</small>` : '') },
  situacao:{ l:'Situação', f:s => `${badgeSt(s)} ${['pendente','autorizada','devolvida'].includes(s.status) ? tagIncompleto(s) : ''}`, v:s => rotuloStatus(s) },
  agenda:{ l:'Agendamento', f:s => s.vaga_data ? `${fmtData(s.vaga_data)} ${fmtHora(s.vaga_hora)}<small>${h(s.unidade_executante_nome)} · guia ${h(s.numero_guia)}</small>` : '—', v:s => s.vaga_data || '' },
};

/* =====================================================================
   SOLICITAÇÕES — acompanhamento (todas as etapas)
   ===================================================================== */
async function pgSolicitacoes(el){
  if(pode('solicitacao')) acaoTopo('+ Nova solicitação', 'pri', () => ir('#/solicitacao'));
  const P = params(), pref = 'ls';
  const ini = { st:P.get('status') ?? 'abertas', de:P.get('de') || '', ord:'recentes' };
  el.innerHTML = (papel() === 'solicitante' ? `<p class="muted">Solicitações registradas pela unidade <b>${h(nomeUnidade(S.perfil.unidade_id))}</b>.</p>` : '')
    + filtrosHtml(pref, ini) + `<div id="ls-res"></div><div id="ls-tab">${carregando()}</div>`;
  let rows = await fetchAll(() => sb.from('vw_solicitacoes').select('*').order('id'));
  const atualizar = () => { const f = lerFiltros(pref), l = aplicarFiltros(rows, f); $('#ls-res').innerHTML = resumoFiltro(f, l.length); tab.set(l); };
  const recarregar = async () => { rows = await fetchAll(() => sb.from('vw_solicitacoes').select('*').order('id')); atualizar(); };
  const tab = montarTabela($('#ls-tab', el), { colunas:[COLS_SOL.protocolo, COLS_SOL.paciente, COLS_SOL.procedimento, COLS_SOL.origem, COLS_SOL.risco, COLS_SOL.situacao, COLS_SOL.agenda],
    linhas:[], onClick: s => abrirSolicitacao(s.id, recarregar), rotuloItens:'solicitação(ões)',
    vazio: estado({ titulo:'Nenhuma solicitação encontrada', texto:'Ajuste a situação, o período ou a busca.' }) });
  ligarFiltros(pref, atualizar, { st:'abertas', ord:'recentes' });
  atualizar();
}

/* =====================================================================
   DETALHE DA SOLICITAÇÃO (usado em várias telas)
   ===================================================================== */
async function abrirSolicitacao(id, depois){
  // registrado assim que se sabe o paciente, logo após carregar (abaixo)
  const [s, hist] = await Promise.all([
    q(sb.from('vw_solicitacoes').select('*').eq('id', id).single()),
    q(sb.from('historico').select('*, perfis(nome)').eq('solicitacao_id', id).order('created_at'))
  ]);
  registrarAcesso(s.paciente_id, 'detalhe da solicitação');
  const minhaUnidade = s.unidade_solicitante_id === S.perfil.unidade_id;
  const central = can('admin','regulador','agendador');
  const pend = pendencias(s);
  const acoes = [];
  let m;
  const fim = msg => { if(msg) aviso(msg, 'ok'); atualizarContadores(); depois && depois(); };

  if(['pendente','autorizada','devolvida','agendada'].includes(s.status) && (central || (minhaUnidade && s.status !== 'agendada')))
    acoes.push({ label:'Cancelar solicitação', cls:'err-sec', onClick: async () => { const ok = await cancelarSolicitacao(s); if(ok){ fim(`Solicitação <b>${h(s.protocolo)}</b> cancelada.`); return true; } return false; } });
  if(s.status === 'devolvida' && (minhaUnidade || can('admin','regulador')))
    acoes.push({ label:'Corrigir e reenviar', cls:'pri', onClick: async () => { const ok = await reenviarSolicitacao(s); if(ok) fim(`Solicitação <b>${h(s.protocolo)}</b> reenviada para análise.`); return ok ? true : false; } });
  if(casaStatus(s, 'regulacao') && pode('regulacao'))
    acoes.push({ label:'Analisar ›', cls:'pri', onClick: () => { ir(`#/regulacao?sol=${id}`); } });
  if(casaStatus(s, 'agendar') && pode('agendamento'))
    acoes.push({ label:'Agendar ›', cls:'pri', onClick: () => { ir(`#/agendamento?sol=${id}&pac=${s.paciente_id}`); } });
  if(s.status === 'autorizada' && !s.vaga_id && can('admin','regulador'))
    acoes.push({ label:'Rever autorização', cls:'warn', onClick: async () => {
      const ok = await reverAutorizacao(s); if(ok) fim(`Autorização de <b>${h(s.protocolo)}</b> revista.`); return ok; } });
  if(s.status === 'faltou' && pode('agendamento'))
    acoes.push({ label:'Reagendar ›', cls:'pri', onClick: () => { ir(`#/agendamento?sol=${id}&pac=${s.paciente_id}`); } });
  if(s.status === 'agendada'){
    acoes.push({ label:'Imprimir guia', onClick: () => { imprimirGuia(s); return false; } });
    if(pode('agendamento')) acoes.push({ label:'Remarcar', onClick: () => { ir(`#/agendamento?sol=${id}&pac=${s.paciente_id}`); } });
    if(pode('confirmacao')) acoes.push({ label:'Confirmar atendimento ›', cls:'pri', onClick: () => { ir(`#/confirmacao?guia=${s.numero_guia}`); } });
  }
  acoes.push({ label:'Fechar' });

  m = modal({
    title:`Solicitação ${s.protocolo}`, wide:true, actions:acoes,
    body: `
      <div class="row" style="margin-bottom:10px">${badgeSt(s)} ${badgePrio(s.prioridade, true)} ${s.exige_regulacao ? tagReg() : ''}
        ${s.numero_guia ? `<span class="badge st-agendada">Guia ${h(s.numero_guia)}</span>` : ''}<span class="muted">registrada há ${s.dias_espera} dia(s), em ${fmtDataHora(s.created_at)}</span></div>
      ${esperaDupla(s)}
      ${s.status === 'devolvida' ? alerta('warn', `<b>Motivo:</b> ${h(s.parecer || 'não informado')}<br>Corrija as informações e reenvie para nova análise.`, 'Devolvida pelo regulador') : ''}
      ${s.status === 'negada' ? alerta('err', `<b>Motivo:</b> ${h(s.parecer || 'não informado')}`, 'Solicitação negada') : ''}
      ${pend.length && ['pendente','autorizada','devolvida'].includes(s.status) ? alerta('warn', `Faltam: ${h(pend.join(', '))}.`, 'Registro incompleto') : ''}
      <h3 class="secao-t">Paciente</h3>
      <dl class="dl">
        <div><dt>Nome</dt><dd>${h(s.paciente_nome)}</dd></div>
        <div><dt>Nascimento</dt><dd>${fmtData(s.paciente_nascimento)} (${idade(s.paciente_nascimento)} anos)</dd></div>
        <div><dt>CPF</dt><dd>${fCPF(s.paciente_cpf)}</dd></div>
        <div><dt>Cartão SUS</dt><dd>${fCNS(s.paciente_cns)}</dd></div>
        <div><dt>Telefones</dt><dd>${fTel(s.paciente_telefone)}${s.paciente_telefone2 ? ' / ' + fTel(s.paciente_telefone2) : ''}</dd></div>
        <div><dt>Endereço</dt><dd>${h(s.paciente_endereco || '—')}</dd></div>
      </dl>
      ${pode('pacientes') ? `<button type="button" class="btn sm link" id="ver-ficha">Abrir ficha do paciente</button>` : ''}
      <h3 class="secao-t">Pedido médico</h3>
      <dl class="dl">
        <div><dt>Procedimento</dt><dd>${h(s.procedimento_nome)}${s.procedimento_codigo ? ` <small class="muted">SIGTAP ${h(s.procedimento_codigo)}</small>` : ''}</dd></div>
        <div><dt>Emitido por</dt><dd>${h(s.unidade_origem_nome || '—')}</dd></div>
        <div><dt>Profissional</dt><dd>${h(s.profissional_solicitante || '—')} ${h(s.crm_solicitante || '')}</dd></div>
        <div><dt>Data do pedido</dt><dd>${fmtData(s.data_pedido)}</dd></div>
        <div><dt>CID-10</dt><dd>${h(s.cid10 || '—')}</dd></div>
        <div><dt>Registrada em</dt><dd>${h(s.unidade_solicitante_nome)}</dd></div>
      </dl>
      <div class="field"><span class="lbl">Justificativa clínica</span>${s.justificativa ? `<div class="box">${h(s.justificativa)}</div>` : '<p class="muted">Não informada.</p>'}</div>
      ${s.data_regulacao ? `<h3 class="secao-t">Regulação</h3><dl class="dl"><div><dt>Regulador</dt><dd>${h(s.regulador_nome || '—')}</dd></div><div><dt>Data</dt><dd>${fmtDataHora(s.data_regulacao)}</dd></div>
        ${s.parecer ? `<div style="grid-column:1/-1"><dt>Parecer</dt><dd>${h(s.parecer)}</dd></div>` : ''}</dl>` : ''}
      ${s.vaga_data ? `<h3 class="secao-t">Agendamento</h3>
        <dl class="dl"><div><dt>Data e hora</dt><dd>${dataExtenso(s.vaga_data)} às ${fmtHora(s.vaga_hora)}</dd></div>
        <div><dt>Local</dt><dd>${h(s.unidade_executante_nome)}</dd></div><div><dt>Profissional</dt><dd>${h(s.vaga_profissional || '—')}</dd></div>
        <div><dt>Guia</dt><dd>${h(s.numero_guia)}</dd></div></dl>` : ''}
      <h3 class="secao-t">Histórico</h3>
      <ol class="timeline">${hist.map(x => `<li>${badgeSt(x.status_novo === 'pendente' && s.exige_regulacao ? 'regulacao' : x.status_novo)} <small>${fmtDataHora(x.created_at)} · ${h(x.perfis?.nome || 'sistema')}</small>
        ${x.observacao ? `<div>${h(x.observacao)}</div>` : ''}</li>`).join('')}</ol>`
  });
  const vf = $('#ver-ficha', m); if(vf) vf.onclick = () => { m.close(); fichaPaciente(s.paciente_id, 'historico'); };
}

/* Cancelar: explica o efeito e exige motivo */
/* Antes da migração 002, autorização equivocada não tinha volta: a única
   saída era cancelar, o que encerra a solicitação e tira o paciente da
   fila. Agora o regulador devolve à unidade ou nega, com parecer
   obrigatório, enquanto não houver vaga marcada. */
async function reverAutorizacao(s){
  const r = await confirmar({
    titulo:'Rever autorização', botao:'Devolver à unidade', cls:'warn',
    html:`<p><b>${h(s.paciente_nome)}</b> — ${h(s.procedimento_nome)} (protocolo ${h(s.protocolo)})</p>`
      + alerta('info', 'A solicitação volta para a unidade de origem, que pode corrigir e reenviar. '
        + 'O tempo de fila já acumulado é mantido e tudo fica no histórico, com o seu nome.', 'O que acontece'),
    campo:{ label:'Motivo da revisão', obrigatorio:true, min:5,
      dica:'Obrigatório. A unidade de origem vê este texto.' } });
  if(!r.ok) return false;
  await q(sb.rpc('regular_solicitacao', { p_id:s.id, p_acao:'devolver', p_prioridade:null, p_parecer:r.texto }));
  return true;
}

async function cancelarSolicitacao(s){
  const r = await confirmar({ titulo:'Cancelar solicitação', botao:'Cancelar solicitação', cls:'err',
    html: `<p><b>${h(s.paciente_nome)}</b> — ${h(s.procedimento_nome)} (protocolo ${h(s.protocolo)})</p>
      ${alerta('warn', `A solicitação sai da fila e não poderá ser reaberta.${s.vaga_id ? ` A vaga de <b>${fmtData(s.vaga_data)} às ${fmtHora(s.vaga_hora)}</b> será liberada para outro paciente.` : ''}`, 'O que acontece')}`,
    campo:{ label:'Motivo do cancelamento', obrigatorio:true, dica:'Ex.: paciente desistiu, já realizou em outro serviço, mudou de cidade.' } });
  if(!r.ok) return false;
  await q(sb.rpc('registrar_desfecho', { p_id:s.id, p_status:'cancelada', p_obs:r.texto }));
  return true;
}
/* Reenviar devolvida */
async function reenviarSolicitacao(s){
  const r = await confirmar({ titulo:'Corrigir e reenviar para análise', botao:'Reenviar para análise', cls:'pri',
    html: alerta('warn', `<b>Motivo da devolução:</b> ${h(s.parecer || 'não informado')}`) + '<p>Revise a justificativa clínica respondendo ao que o regulador pediu.</p>',
    campo:{ label:'Justificativa clínica revisada', obrigatorio:true, min:20, valor:s.justificativa || '', msg:'Escreva pelo menos 20 caracteres.', dica:'Inclua as informações pedidas pelo regulador.' } });
  if(!r.ok) return false;
  await q(sb.rpc('reenviar_solicitacao', { p_id:s.id, p_justificativa:r.texto }));
  return true;
}

/* =====================================================================
   ANÁLISE REGULATÓRIA — área de trabalho do regulador
   Lista (esquerda) + detalhe com ações (direita).
   Ações: autorizar, devolver à unidade, negar (regular_solicitacao).
   ===================================================================== */
async function pgRegulacao(el){
  const P = params(), pref = 'rg';
  let rows = [], lista = [], sel = null, compacta = store.get('regula_compacta') || false;
  el.innerHTML = filtrosHtml(pref, { st:'regulacao' }, { status:['regulacao','pendente','devolvida','autorizada','negada',''] })
    + `<div class="row no-print" style="margin:-4px 0 12px"><span id="rg-res" class="spacer"></span>
        <label class="chk"><input type="checkbox" id="rg-comp" ${compacta?'checked':''}> Lista compacta</label></div>
      <div class="mestre ${compacta?'compacta':''}" id="rg-mestre">
        <section class="card" aria-labelledby="rg-lt" style="padding:12px"><h2 id="rg-lt" class="sr-only">Solicitações</h2><div class="fila" id="rg-fila" role="listbox" aria-label="Solicitações para análise"></div></section>
        <section class="card" id="rg-det" aria-live="polite" tabindex="-1">${estado({ titulo:'Selecione uma solicitação', texto:'Escolha um item da lista para ver os dados clínicos e registrar a análise.' })}</section>
      </div>`;

  const carregar = async () => { rows = await fetchAll(() => sb.from('vw_solicitacoes').select('*').order('id')); };
  const filtrar = (manter=true) => {
    const f = lerFiltros(pref); lista = aplicarFiltros(rows, f);
    $('#rg-res').innerHTML = resumoFiltro(f, lista.length);
    $('#rg-fila').innerHTML = lista.length ? lista.map(s => `<button type="button" class="it" role="option" aria-selected="${sel?.id===s.id}" data-id="${s.id}">
        <span class="t1"><b>${h(s.paciente_nome)}</b>${badgePrio(s.prioridade)}</span>
        <small>${h(s.procedimento_nome)}</small>
        <small class="x">${h(s.unidade_origem_nome || s.unidade_solicitante_nome)} · pedido ${fmtData(s.data_pedido)} · espera ${s.dias_espera} dia(s)</small>
        <span class="tags x">${badgeSt(s)} ${tagIncompleto(s)}</span></button>`).join('')
      : estado({ titulo:'Nenhuma solicitação', texto: f.st === 'regulacao' ? 'Não há solicitações aguardando análise com estes filtros.' : 'Ajuste os filtros.' });
    $$('#rg-fila .it').forEach(b => b.onclick = () => selecionar(rows.find(s => s.id == b.dataset.id), true));
    if(manter && sel){ const n = rows.find(s => s.id === sel.id); if(n) selecionar(n); }
  };

  async function selecionar(s, rolar){
    sel = s;
    $$('#rg-fila .it').forEach(b => b.setAttribute('aria-selected', +b.dataset.id === s.id));
    const det = $('#rg-det');
    const hist = await q(sb.from('historico').select('*, perfis(nome)').eq('solicitacao_id', s.id).order('created_at'));
    const pend = pendencias(s), analisavel = s.status === 'pendente';
    const crit = CRITERIOS_RISCO[s.prioridade] || [];
    det.innerHTML = `
      <div class="card-h"><h2>${h(s.paciente_nome)}</h2><span class="spacer"></span>${badgeSt(s)}</div>
      <p class="muted" style="margin-top:-6px">Protocolo ${h(s.protocolo)} · registrada em ${fmtDataHora(s.created_at)} · espera de ${s.dias_espera} dia(s)</p>
      ${pend.length ? alerta('warn', `Faltam: ${h(pend.join(', '))}. Se impedir a análise, use <b>Devolver à unidade</b> e diga o que falta.`, 'Registro incompleto') : ''}
      ${s.status === 'devolvida' ? alerta('warn', `Devolvida em ${fmtDataHora(s.data_regulacao)} por ${h(s.regulador_nome || '—')}: ${h(s.parecer || '')}. Aguardando correção da unidade.`, 'Com a unidade') : ''}
      ${['autorizada','negada'].includes(s.status) ? alerta(s.status==='negada'?'err':'ok', `${s.status==='negada'?'Negada':'Autorizada'} em ${fmtDataHora(s.data_regulacao)} por ${h(s.regulador_nome || '—')}${s.parecer ? ': ' + h(s.parecer) : ''}.`, 'Análise registrada') : ''}
      <h3 class="secao-t">Pedido</h3>
      <dl class="dl">
        <div><dt>Procedimento</dt><dd>${h(s.procedimento_nome)} ${s.exige_regulacao ? tagReg() : ''}</dd></div>
        <div><dt>Risco informado</dt><dd>${badgePrio(s.prioridade, true)}</dd></div>
        <div><dt>CID-10</dt><dd>${h(s.cid10 || '—')}</dd></div>
        <div><dt>Data do pedido</dt><dd>${fmtData(s.data_pedido)}</dd></div>
        <div><dt>Origem</dt><dd>${h(s.unidade_origem_nome || '—')}</dd></div>
        <div><dt>Solicitante</dt><dd>${h(s.profissional_solicitante || '—')} ${h(s.crm_solicitante || '')}</dd></div>
      </dl>
      <div class="field"><span class="lbl">Justificativa clínica</span>${s.justificativa ? `<div class="box">${h(s.justificativa)}</div>` : '<p class="muted">Não informada.</p>'}</div>
      <h3 class="secao-t">Paciente</h3>
      <dl class="dl"><div><dt>Idade</dt><dd>${idade(s.paciente_nascimento)} anos (${fmtData(s.paciente_nascimento)})</dd></div>
        <div><dt>Sexo</dt><dd>${{F:'Feminino',M:'Masculino',I:'Não informado'}[s.paciente_sexo] || '—'}</dd></div>
        <div><dt>Cartão SUS</dt><dd>${fCNS(s.paciente_cns)}</dd></div><div><dt>Contato</dt><dd>${fTel(s.paciente_telefone)}</dd></div></dl>
      <details style="margin:10px 0"><summary style="cursor:pointer;font-weight:700;color:var(--azul)">Histórico completo (${hist.length})</summary>
        <ol class="timeline" style="margin-top:10px">${hist.map(x => `<li>${badgeSt(x.status_novo === 'pendente' && s.exige_regulacao ? 'regulacao' : x.status_novo)} <small>${fmtDataHora(x.created_at)} · ${h(x.perfis?.nome || 'sistema')}</small>${x.observacao ? `<div>${h(x.observacao)}</div>` : ''}</li>`).join('')}</ol></details>
      ${analisavel ? `<h3 class="secao-t">Análise</h3>
        <div id="rg-err"></div>
        <div class="grid">
          <div class="field s2"><label for="rg-prio">Classificação de risco final</label>
            <span class="dica" id="rg-prio-d">Mantenha ou reclassifique conforme o protocolo municipal.</span>
            <select id="rg-prio" aria-describedby="rg-prio-d">${Object.entries(PRIORIDADES).map(([k, p]) => `<option value="${k}" ${k===s.prioridade?'selected':''}>${p.s} ${p.l} — ${h(p.d)}</option>`).join('')}</select></div>
          <div class="field s2"><span class="lbl">Critérios do protocolo local</span>
            <span class="dica">${crit.length ? crit.map(h).join('; ') : 'Nenhum critério local cadastrado para esta cor (configurável em CRITERIOS_RISCO).'}</span></div>
          <div class="field full"><label for="rg-par">Parecer do regulador <span class="opc">(obrigatório para devolver ou negar)</span></label>
            <span class="dica" id="rg-par-d">Para devolver, diga exatamente o que a unidade precisa incluir. Para negar, explique o motivo e a orientação.</span>
            <p class="erro-msg hidden" id="rg-par-e"></p>
            <textarea id="rg-par" rows="3" aria-describedby="rg-par-d rg-par-e"></textarea></div>
        </div>
        <div class="acoes" style="margin-top:14px">
          <button type="button" class="btn ok lg" data-acao="autorizar">✓ Autorizar</button>
          <button type="button" class="btn warn lg" data-acao="devolver">↩ Devolver à unidade</button>
          <button type="button" class="btn err lg" data-acao="negar">✕ Negar</button>
          <span class="spacer"></span><button type="button" class="btn link" id="rg-abrir">Abrir detalhes completos</button>
        </div>` : `<div class="acoes"><button type="button" class="btn" id="rg-abrir">Abrir detalhes completos</button>
          ${casaStatus(s, 'agendar') && pode('agendamento') ? `<a class="btn pri" href="#/agendamento?sol=${s.id}&pac=${s.paciente_id}">Agendar ›</a>` : ''}</div>`}`;
    $('#rg-abrir', det).onclick = () => abrirSolicitacao(s.id, async () => { await carregar(); filtrar(); });
    $$('[data-acao]', det).forEach(b => b.onclick = () => acao(b.dataset.acao, s, b));
    if(rolar && matchMedia('(max-width:1100px)').matches) det.scrollIntoView({ behavior:'smooth', block:'start' });
  }

  async function acao(tipo, s, btn){
    const par = $('#rg-par').value.trim(), prio = $('#rg-prio').value;
    const err = $('#rg-par-e'), ta = $('#rg-par');
    err.classList.add('hidden'); ta.removeAttribute('aria-invalid');
    if(tipo !== 'autorizar' && par.length < 10){
      err.textContent = tipo === 'devolver' ? 'Escreva o que a unidade precisa corrigir ou incluir (pelo menos 10 caracteres).' : 'Escreva o motivo da negativa (pelo menos 10 caracteres).';
      err.classList.remove('hidden'); ta.setAttribute('aria-invalid','true'); ta.focus(); return;
    }
    const nome = { autorizar:'Autorizar', devolver:'Devolver à unidade', negar:'Negar' }[tipo];
    const efeito = { autorizar:'A solicitação fica liberada para o agendamento.', devolver:'A solicitação volta para a unidade solicitante, que deve corrigir e reenviar. Ela sai desta lista até ser reenviada.', negar:'A solicitação é encerrada e sai da fila. A unidade verá o motivo.' }[tipo];
    const r = await confirmar({ titulo:`${nome} — confirmar`, botao:nome, cls:{ autorizar:'ok', devolver:'warn', negar:'err' }[tipo],
      html:`<dl class="dl"><div><dt>Paciente</dt><dd>${h(s.paciente_nome)}</dd></div><div><dt>Procedimento</dt><dd>${h(s.procedimento_nome)}</dd></div>
        <div><dt>Risco final</dt><dd>${badgePrio(prio, true)}${prio !== s.prioridade ? `<br><small class="muted">reclassificado de ${PRIORIDADES[s.prioridade].l}</small>` : ''}</dd></div></dl>
        ${par ? `<div class="field"><span class="lbl">Parecer</span><div class="box">${h(par)}</div></div>` : ''}${alerta('info', efeito, 'O que acontece')}` });
    if(!r.ok) return;
    await ocupado(btn, async () => {
      try {
        await q(sb.rpc('regular_solicitacao', { p_id:s.id, p_acao:tipo, p_prioridade:prio, p_parecer:par }));
        const idx = lista.findIndex(x => x.id === s.id);
        aviso(`<b>${h(s.paciente_nome)}</b> — ${h(s.procedimento_nome)} (protocolo ${h(s.protocolo)}): <b>${{ autorizar:'autorizada', devolver:'devolvida à unidade', negar:'negada' }[tipo]}</b> em ${fmtDataHora(new Date())}. Registrado no histórico.`, tipo === 'negar' ? 'warn' : 'ok', 'Análise registrada');
        await carregar(); sel = null; filtrar(false); atualizarContadores();
        const prox = lista[Math.min(idx, lista.length - 1)];
        if(prox) selecionar(prox); else $('#rg-det').innerHTML = estado({ tipo:'sucesso', titulo:'Fila analisada', texto:'Não há mais solicitações com estes filtros.' });
        $('#rg-det').focus();
      } catch(e){ $('#rg-err').innerHTML = alerta('err', h(e.message), 'Não foi possível registrar'); }
    });
  }

  $('#rg-comp').onchange = e => { compacta = e.target.checked; store.set('regula_compacta', compacta); $('#rg-mestre').classList.toggle('compacta', compacta); };
  ligarFiltros(pref, () => filtrar(), { st:'regulacao', ord:'prioridade' });
  await carregar(); filtrar(false);
  const sid = +P.get('sol');
  if(sid){ const s = rows.find(x => x.id === sid); if(s){ if(!lista.includes(s)){ $('#rg-st').value = ''; filtrar(false); } selecionar(s); } }
  else if(lista.length) selecionar(lista[0]);
}

/* =====================================================================
   FILA DE ESPERA — gestão de toda a fila
   ===================================================================== */
async function pgFila(el){
  const P = params(), pref = 'fl';
  let vis = store.get('regula_fila_vis') || 'tabela';
  const ini = { st:P.get('status') ?? 'abertas', de:P.get('de') || '', ord:'prioridade' };
  el.innerHTML = `<div id="fl-chips" class="chips no-print" style="margin-bottom:12px"></div>` + filtrosHtml(pref, ini)
    + `<div class="row no-print" style="margin:-4px 0 10px"><span id="fl-res" class="spacer"></span>
        <div class="seg" role="group" aria-label="Forma de exibição"><button type="button" data-v="tabela">Lista compacta</button><button type="button" data-v="cartoes">Detalhes</button></div>
        <button type="button" class="btn sm" id="fl-csv">Exportar CSV</button></div><div id="fl-corpo"></div>`;
  let rows = await fetchAll(() => sb.from('vw_solicitacoes').select('*').order('id'));
  const tabEl = $('#fl-corpo', el);
  const recarregar = async () => { rows = await fetchAll(() => sb.from('vw_solicitacoes').select('*').order('id')); atualizar(); };
  let tab = null, atual = [];
  function atualizar(){
    const f = lerFiltros(pref); atual = aplicarFiltros(rows, f);
    $('#fl-res').innerHTML = resumoFiltro(f, atual.length);
    const cont = k => rows.filter(s => casaStatus(s, k)).length;
    $('#fl-chips').innerHTML = [['regulacao'], ['agendar'], ['devolvida'], ['agendada']].map(([k]) =>
      `<button type="button" class="chip" data-st="${k}" aria-pressed="${f.st===k}" style="${f.st===k?'background:var(--azul);color:#fff;border-color:var(--azul)':''}">${h(FILTRO_STATUS.find(x => x[0]===k)[1])}: <b>${cont(k)}</b></button>`).join('');
    $$('#fl-chips .chip').forEach(c => c.onclick = () => { $('#fl-st').value = c.dataset.st; atualizar(); });
    $$('[data-v]', el).forEach(b => b.setAttribute('aria-pressed', b.dataset.v === vis));
    if(vis === 'tabela'){
      tab = montarTabela(tabEl, { colunas:[COLS_SOL.protocolo, COLS_SOL.paciente, COLS_SOL.procedimento, COLS_SOL.origem, COLS_SOL.risco, COLS_SOL.espera, COLS_SOL.situacao],
        linhas:atual, onClick: s => abrirSolicitacao(s.id, recarregar), rotuloItens:'solicitação(ões)', vazio: estado({ titulo:'Fila vazia com estes filtros' }) });
    } else {
      tabEl.innerHTML = atual.length ? `<div style="display:grid;grid-template-columns:repeat(auto-fill,minmax(320px,1fr));gap:12px">${atual.slice(0, 120).map(s => `
        <article class="card" style="margin:0"><div class="card-h"><h3 style="flex:1">${h(s.paciente_nome)}</h3>${badgePrio(s.prioridade)}</div>
          <p style="margin:0 0 6px"><b>${h(s.procedimento_nome)}</b> ${s.exige_regulacao ? tagReg() : ''}</p>
          <p class="muted" style="margin:0 0 6px;font-size:13px">Protocolo ${h(s.protocolo)} · ${h(s.unidade_origem_nome || '—')} · pedido ${fmtData(s.data_pedido)} · espera ${s.dias_espera} dia(s)</p>
          <p style="margin:0 0 8px">${badgeSt(s)} ${tagIncompleto(s)}</p>
          ${s.justificativa ? `<p style="font-size:13px;margin:0 0 8px">${h(s.justificativa.slice(0, 160))}${s.justificativa.length > 160 ? '…' : ''}</p>` : ''}
          <button type="button" class="btn sm" data-abrir="${s.id}">Ver detalhes e histórico</button></article>`).join('')}</div>
          ${atual.length > 120 ? '<p class="muted">Mostrando os 120 primeiros. Use os filtros ou a lista compacta.</p>' : ''}`
        : estado({ titulo:'Fila vazia com estes filtros' });
      $$('[data-abrir]', tabEl).forEach(b => b.onclick = () => abrirSolicitacao(+b.dataset.abrir, recarregar));
    }
  }
  $$('[data-v]', el).forEach(b => b.onclick = () => { vis = b.dataset.v; store.set('regula_fila_vis', vis); atualizar(); });
  $('#fl-csv', el).onclick = () => baixarCSV(`fila_${hojeISO()}`, ['Protocolo','Registrada','Paciente','CPF','Procedimento','Origem','Data do pedido','Risco','Espera (dias)','Situação'],
    atual.map(s => [s.protocolo, fmtData(s.created_at), s.paciente_nome, cpfOculto(s.paciente_cpf), s.procedimento_nome, s.unidade_origem_nome || '', fmtData(s.data_pedido), PRIORIDADES[s.prioridade].l, s.dias_espera, rotuloStatus(s)]));
  ligarFiltros(pref, atualizar, { st:'abertas', ord:'prioridade' });
  atualizar();
}

/* =====================================================================
   AGENDAMENTO — fila pronta para agendar + escolha da vaga
   ===================================================================== */
async function pgAgendamento(el){
  const P = params();
  let lista = [], sel = null, rows = [];
  const modoIni = P.get('modo') || 'espera';
  el.innerHTML = `<form class="filtros no-print" id="ag-f" role="search" aria-label="Filtros da fila">
      <div class="field"><label for="ag-modo">Mostrar</label><select id="ag-modo"><option value="espera" ${modoIni==='espera'?'selected':''}>Aguardando agendamento</option><option value="agendadas" ${modoIni==='agendadas'?'selected':''}>Já agendadas (para remarcar)</option></select></div>
      <div class="field cresce"><label for="ag-txt">Buscar</label><input type="search" id="ag-txt" placeholder="Nome, CPF, Cartão SUS ou protocolo"></div>
      <div class="field"><label for="ag-proc">Procedimento</label><select id="ag-proc">${optList(S.procedimentos, '', 'Todos')}</select></div>
    </form>
    <div id="ag-reg"></div>
    <div class="mestre">
      <section class="card" style="padding:12px" aria-labelledby="ag-lt"><div class="card-h" style="margin-bottom:8px"><h2 id="ag-lt">Fila</h2><span class="sub" id="ag-n"></span></div>
        <div id="ag-filtro-pac"></div><div class="fila" id="ag-fila" role="listbox" aria-label="Pacientes na fila"></div></section>
      <section class="card" id="ag-dir" tabindex="-1" aria-live="polite">${estado({ titulo:'Selecione um paciente na fila', texto:'A fila está ordenada por classificação de risco e, depois, pelo tempo de espera.' })}</section>
    </div>`;

  const carregar = async () => { rows = await fetchAll(() => sb.from('vw_solicitacoes').select('*').order('id')); };
  const filtrar = () => {
    const modo = $('#ag-modo').value, t = $('#ag-txt').value.trim().toLowerCase(), d = dig(t), proc = $('#ag-proc').value;
    lista = rows.filter(s => modo === 'espera' ? casaStatus(s, 'agendar') : (s.status === 'agendada' && s.vaga_data >= hojeISO()))
      .filter(s => (!proc || s.procedimento_id == proc) && (!P.get('pac') || s.paciente_id == P.get('pac'))
        && (!t || s.paciente_nome.toLowerCase().includes(t) || s.protocolo.includes(t) || (d.length >= 6 && (s.paciente_cpf === d || s.paciente_cns === d))));
    lista.sort(modo === 'espera' ? ((a, b) => a.peso_prioridade - b.peso_prioridade || a.created_at.localeCompare(b.created_at))
                                 : ((a, b) => (a.vaga_data + a.vaga_hora).localeCompare(b.vaga_data + b.vaga_hora)));
    const nReg = rows.filter(s => casaStatus(s, 'regulacao') && (!P.get('pac') || s.paciente_id == P.get('pac'))).length;
    $('#ag-reg').innerHTML = nReg && modo === 'espera' ? alerta('info', `${nReg} solicitação(ões) ${P.get('pac') ? 'deste paciente ' : ''}aguardam a <b>análise regulatória</b> e ainda não podem ser agendadas.${pode('fila') ? ' <a href="#/fila?status=regulacao">Ver na fila</a>' : ''}`) : '';
    $('#ag-n').textContent = `${lista.length} paciente(s)`;
    $('#ag-filtro-pac').innerHTML = P.get('pac') ? `<div class="alert info" style="margin-bottom:8px"><div>Mostrando apenas um paciente. <a href="#/agendamento">Ver a fila completa</a></div></div>` : '';
    $('#ag-fila').innerHTML = lista.length ? lista.map(s => `<button type="button" class="it" role="option" aria-selected="${sel?.id===s.id}" data-id="${s.id}">
        <span class="t1"><b>${h(s.paciente_nome)}</b>${badgePrio(s.prioridade)}</span><small>${h(s.procedimento_nome)}</small>
        <small>${s.status === 'agendada' ? `Agendado ${fmtData(s.vaga_data)} ${fmtHora(s.vaga_hora)} · guia ${h(s.numero_guia)}` : `Protocolo ${h(s.protocolo)} · aguardando há ${s.dias_espera} dia(s)`}</small></button>`).join('')
      : estado({ titulo: modo === 'espera' ? 'Ninguém aguardando agendamento' : 'Nenhum agendamento futuro', texto:'Ajuste os filtros ou a busca.' });
    $$('#ag-fila .it').forEach(b => b.onclick = () => selecionar(lista.find(s => s.id == b.dataset.id), true));
  };

  function limpar(){ sel = null; $('#ag-dir').innerHTML = estado({ titulo:'Selecione um paciente na fila' }); }

  function selecionar(s, rolar){
    sel = s;
    $$('#ag-fila .it').forEach(b => b.setAttribute('aria-selected', +b.dataset.id === s.id));
    const locais = locaisDoProc(s.procedimento_id), rem = s.status === 'agendada';
    const box = $('#ag-dir');
    box.innerHTML = `
      <div class="card-h"><h2>${rem ? 'Remarcar' : 'Agendar'}: ${h(s.procedimento_nome)}</h2><span class="spacer"></span>${badgePrio(s.prioridade)}</div>
      <h3 class="secao-t">Resumo da solicitação</h3>
      <dl class="dl">
        <div><dt>Paciente</dt><dd>${h(s.paciente_nome)}</dd></div><div><dt>Idade</dt><dd>${idade(s.paciente_nascimento)} anos</dd></div>
        <div><dt>Contato</dt><dd>${fTel(s.paciente_telefone)}</dd></div><div><dt>CPF</dt><dd>${fCPF(s.paciente_cpf)}</dd></div>
        <div><dt>Protocolo</dt><dd>${h(s.protocolo)}</dd></div><div><dt>Pedido de</dt><dd>${h(s.unidade_origem_nome || s.unidade_solicitante_nome)}, ${fmtData(s.data_pedido)}</dd></div>
        <div><dt>Situação</dt><dd>${badgeSt(s)}</dd></div><div><dt>Espera</dt><dd>${s.dias_espera} dia(s)</dd></div>
      </dl>
      ${rem ? alerta('warn', `Agendamento atual: <b>${dataExtenso(s.vaga_data)} às ${fmtHora(s.vaga_hora)}</b> — ${h(s.unidade_executante_nome)} (guia ${h(s.numero_guia)}). Ao escolher outro horário, esta vaga é liberada e a guia é mantida.`, 'Remarcação') : ''}
      <h3 class="secao-t">Vagas livres</h3>
      <div class="filtros" style="margin-bottom:4px">
        <div class="field"><label for="ag-local">Local</label><select id="ag-local">${optList(locais, '', locais.length > 1 ? 'Todos os locais' : null)}</select></div>
        <div class="field"><label for="ag-prof">Profissional</label><select id="ag-prof"><option value="">Todos</option></select></div>
        <div class="field"><label for="ag-de">A partir de</label><input type="date" id="ag-de" value="${hojeISO()}" min="${hojeISO()}"></div>
      </div>
      <p class="muted" id="ag-vn" aria-live="polite" style="margin:4px 0"></p>
      <div class="slots" id="ag-slots" role="group" aria-label="Horários disponíveis"></div>
      <div id="ag-escolha"></div>
      <div class="acoes" style="border-top:1px solid var(--borda);padding-top:12px">
        <button type="button" class="btn link" id="ag-det">Ver detalhes e histórico</button>
        <button type="button" class="btn err-sec" id="ag-canc">Cancelar solicitação</button>
        <span class="spacer"></span>
        <button type="button" class="btn pri lg" id="ag-ok" disabled>Revisar e confirmar ›</button>
      </div>`;
    let vagaSel = null, grupos = {}, profsCarregados = false;
    const carregarVagas = async () => {
      vagaSel = null; $('#ag-ok').disabled = true; $('#ag-escolha').innerHTML = '';
      $('#ag-slots').innerHTML = carregando('Buscando vagas…', true);
      let qb = sb.from('vagas').select('id,data,hora,profissional,unidade_executante_id').eq('procedimento_id', s.procedimento_id)
        .eq('status','livre').gte('data', $('#ag-de').value || hojeISO()).order('data').order('hora').limit(1000);
      const loc = $('#ag-local').value; if(loc) qb = qb.eq('unidade_executante_id', loc);
      let vagas = await q(qb);
      if(!profsCarregados){ profsCarregados = true; const ps = [...new Set(vagas.map(v => v.profissional).filter(Boolean))].sort();
        $('#ag-prof').innerHTML = '<option value="">Todos</option>' + ps.map(p => `<option>${h(p)}</option>`).join(''); }
      const pf = $('#ag-prof').value; if(pf) vagas = vagas.filter(v => v.profissional === pf);
      grupos = {};
      vagas.forEach(v => { const k = [v.data, v.hora, v.unidade_executante_id, v.profissional||''].join('|'); (grupos[k] ||= { ...v, qtd:0 }).qtd++; });
      const porDia = {}; Object.values(grupos).forEach(g => (porDia[g.data] ||= []).push(g));
      const dias = Object.keys(porDia).length;
      $('#ag-vn').textContent = vagas.length ? `${vagas.length} vaga(s) livre(s) em ${dias} dia(s).` : '';
      if(!vagas.length){
        const filtrado = loc || pf || $('#ag-de').value > hojeISO();
        $('#ag-slots').innerHTML = estado({ titulo:'Nenhuma vaga livre', texto:`Não há vaga livre para <b>${h(s.procedimento_nome)}</b>${filtrado ? ' com estes filtros' : ''}. A solicitação continua na fila.`,
          acoes:[ ...(filtrado ? [{ label:'Buscar em todos os locais e datas', id:'todos', cls:'pri' }] : []), { label:'Voltar para a fila', id:'fila' },
            ...(pode('agendas') ? [{ label:'Cadastrar agenda', href:'#/agendas' }] : []) ] });
        const t = $('[data-estado-acao=todos]', box); if(t) t.onclick = () => { $('#ag-local').value = ''; $('#ag-prof').value = ''; $('#ag-de').value = hojeISO(); carregarVagas(); };
        $('[data-estado-acao=fila]', box).onclick = () => $('#ag-fila .it[aria-selected=true]')?.focus();
        return;
      }
      $('#ag-slots').innerHTML = Object.entries(porDia).map(([d, l]) => `<div class="slot-day"><h4>${dataExtenso(d)}${feriado(d) ? ` <span class="badge st-faltou">${h(feriado(d))}</span>` : ''}</h4><div class="row">
        ${l.map(g => { const k = [g.data, g.hora, g.unidade_executante_id, g.profissional||''].join('|');
          return `<button type="button" class="slot" aria-pressed="false" data-k="${h(k)}" aria-label="${dataExtenso(g.data)} às ${fmtHora(g.hora)}, ${h(nomeUnidade(g.unidade_executante_id))}${g.profissional ? ', ' + h(g.profissional) : ''}, ${g.qtd} vaga(s)">
            <b>${fmtHora(g.hora)}</b>${g.qtd > 1 ? ` <span class="muted">(${g.qtd} vagas)</span>` : ''}<small>${h(nomeUnidade(g.unidade_executante_id))}${g.profissional ? ' · ' + h(g.profissional) : ''}</small></button>`; }).join('')}
        </div></div>`).join('');
      $$('.slot', box).forEach(b => b.onclick = () => {
        $$('.slot', box).forEach(x => x.setAttribute('aria-pressed', 'false')); b.setAttribute('aria-pressed', 'true');
        vagaSel = grupos[b.dataset.k]; $('#ag-ok').disabled = false;
        $('#ag-escolha').innerHTML = alerta('info', `Horário escolhido: <b>${dataExtenso(vagaSel.data)} às ${fmtHora(vagaSel.hora)}</b> — ${h(nomeUnidade(vagaSel.unidade_executante_id))}${vagaSel.profissional ? ' · ' + h(vagaSel.profissional) : ''}`);
      });
    };
    $('#ag-local').onchange = () => { profsCarregados = false; carregarVagas(); }; $('#ag-de').onchange = carregarVagas; $('#ag-prof').onchange = carregarVagas;
    $('#ag-det').onclick = () => abrirSolicitacao(s.id, async () => { await carregar(); filtrar(); limpar(); });
    $('#ag-canc').onclick = async () => {
      try { if(await cancelarSolicitacao(s)){ aviso(`Solicitação <b>${h(s.protocolo)}</b> de ${h(s.paciente_nome)} cancelada.`, 'ok'); limpar(); await carregar(); filtrar(); atualizarContadores(); } }
      catch(e){ toast(e.message, 'err'); }
    };
    $('#ag-ok').onclick = () => confirmarAgendamento(s, vagaSel, rem);
    carregarVagas();
    if(rolar && matchMedia('(max-width:1100px)').matches) box.scrollIntoView({ behavior:'smooth', block:'start' });
  }

  async function confirmarAgendamento(s, v, rem){
    const u = S.unidades.find(x => x.id === v.unidade_executante_id) || {};
    const aposFalta = s.status === 'faltou';
    const r = await confirmar({
      titulo: aposFalta ? 'Reagendar após falta' : (rem ? 'Confirmar remarcação' : 'Confirmar agendamento'),
      botao: aposFalta ? 'Reagendar' : (rem ? 'Remarcar' : 'Confirmar agendamento'), cls:'pri',
      // O banco exige o motivo do reagendamento depois de uma falta: fica no histórico.
      campo: aposFalta ? { label:'Motivo do reagendamento', obrigatorio:true,
        dica:'Fica registrado no histórico da solicitação. Ex.: paciente justificou a ausência e pediu nova data.' } : null,
      html:`<dl class="dl"><div><dt>Paciente</dt><dd>${h(s.paciente_nome)}</dd></div><div><dt>Procedimento</dt><dd>${h(s.procedimento_nome)}</dd></div>
        <div><dt>Data e hora</dt><dd><b>${dataExtenso(v.data)} às ${fmtHora(v.hora)}</b></dd></div><div><dt>Local</dt><dd>${h(u.nome)}${u.endereco ? `<small class="muted" style="display:block">${h(u.endereco)}</small>` : ''}</dd></div>
        <div><dt>Profissional</dt><dd>${h(v.profissional || '—')}</dd></div></dl>
        ${rem ? alerta('warn', `A vaga atual (${fmtData(s.vaga_data)} às ${fmtHora(s.vaga_hora)}) será liberada para outro paciente. A guia nº <b>${h(s.numero_guia)}</b> continua a mesma.`, 'O que acontece') : ''}
        ${aposFalta ? alerta('info', `A vaga da falta anterior não volta para a oferta — ela foi consumida e continua nos indicadores. A solicitação original é mantida, com o tempo de fila já acumulado, e a guia nº <b>${h(s.numero_guia)}</b> segue a mesma.`, 'O que acontece') : ''}` });
    if(!r.ok) return;
    try {
      const guia = await q(sb.rpc('agendar', { p_solicitacao:s.id, p_vaga:v.id, p_obs: r.texto || null }));
      const at = await q(sb.from('vw_solicitacoes').select('*').eq('id', s.id).single());
      atualizarContadores();
      aviso(`<b>${h(at.paciente_nome)}</b> — ${h(at.procedimento_nome)}: ${dataExtenso(at.vaga_data)} às ${fmtHora(at.vaga_hora)}, ${h(at.unidade_executante_nome)}. Guia nº <b>${h(guia)}</b>.
        <div class="acoes"><button type="button" class="btn sm pri" id="av-guia">Imprimir guia</button></div>`, 'ok', rem ? 'Remarcação concluída' : 'Agendamento concluído');
      $('#av-guia').onclick = () => imprimirGuia(at);
      modal({ title: rem ? 'Remarcação concluída' : 'Agendamento concluído', body:`
        <div style="text-align:center"><div class="muted">Número da guia</div>
          <div style="font-size:40px;font-weight:800;color:var(--azul);letter-spacing:.08em">${h(guia)}</div>
          <p style="font-size:16px"><b>${h(at.paciente_nome)}</b><br>${h(at.procedimento_nome)}<br><b>${dataExtenso(at.vaga_data)} às ${fmtHora(at.vaga_hora)}</b><br>${h(at.unidade_executante_nome)}</p></div>
        <h3 class="secao-t">Próximos passos</h3>
        <ol style="margin:0;padding-left:20px"><li>Imprima a guia (2 vias) e entregue a do paciente.</li>
          <li>Oriente a chegar 30 minutos antes, com documento com foto, Cartão SUS, esta guia, o pedido médico e exames anteriores.</li>
          <li>Se o paciente não estiver presente, avise pelo telefone ${fTel(at.paciente_telefone)}.</li></ol>`,
        actions:[{ label:'Próximo da fila' }, { label:'Imprimir guia', cls:'pri', onClick: () => { imprimirGuia(at); return false; } }],
        onClose: async () => { limpar(); await carregar(); filtrar(); const p = lista[0]; if(p && !P.get('pac')) selecionar(p); } });
    } catch(e){ $('#ag-escolha').innerHTML = alerta('err', h(e.message), 'Não foi possível agendar'); }
  }

  $('#ag-f').onsubmit = e => e.preventDefault();
  $('#ag-modo').onchange = () => { limpar(); filtrar(); };
  $('#ag-proc').onchange = filtrar;
  $('#ag-txt').oninput = debounce(filtrar);
  await carregar(); filtrar();
  const sid = +P.get('sol');
  if(sid){
    const s = rows.find(x => x.id === sid);
    if(s && s.status === 'agendada' && $('#ag-modo').value !== 'agendadas'){ $('#ag-modo').value = 'agendadas'; filtrar(); }
    if(s && (casaStatus(s, 'agendar') || s.status === 'agendada')) selecionar(s);
    else if(s) $('#ag-dir').innerHTML = estado({ titulo:'Esta solicitação não pode ser agendada agora', texto:`Situação atual: <b>${h(rotuloStatus(s))}</b>.` });
  } else if(P.get('pac') && lista.length) selecionar(lista[0]);
}

/* ---------- Guia de agendamento (2 vias) ---------- */
function imprimirGuia(s){
  registrarAcesso(s.paciente_id, 'impressão de guia');
  const w = window.open('', '_blank');
  if(!w){ toast('O navegador bloqueou a janela de impressão. Permita pop-ups para este arquivo e tente de novo.', 'err'); return; }
  const logo = new URL('assets/regula-posse-emblema.png', location.href).href;
  /* QR com o endereço de acompanhamento. Leva só o protocolo: a data de
     nascimento continua sendo pedida na tela, então guia perdida ou
     fotografada não abre a situação de ninguém. O SVG é gerado aqui, sem
     serviço externo — o protocolo do paciente não sai desta máquina. */
  const acompanhar = urlAcompanhar(s.protocolo);
  let qr = '';
  try {
    /* 120px ≈ 32 mm no papel. Uma URL de acompanhamento dá um QR versão 4,
       de 33 módulos, então isto deixa cada módulo com ~0,95 mm. Testado a
       72px, o módulo ficava com ~0,58 mm e o leitor já não decodificava a
       guia fotografada — tamanho de QR não é detalhe estético, é se o
       paciente consegue ou não apontar a câmera. */
    qr = qrSVG(acompanhar, { lado: 120, nivel: 'M', titulo: `Acompanhar o protocolo ${s.protocolo}` });
  } catch(e){
    registrarErro(e, 'qr da guia');     // guia sem QR ainda serve; sem guia, não
  }
  const via = nome => `<div class="via">
    <div class="cab"><div><img src="${logo}" alt="Regula Posse" style="height:40px"><div style="margin-top:4px"><b>${h(ORGAO)}</b> — Central de Regulação</div><div><b>Guia de Agendamento</b></div></div>
      <div class="g">GUIA Nº<br><b>${h(s.numero_guia)}</b></div></div>
    <div class="dest">${dataExtenso(s.vaga_data)} às ${fmtHora(s.vaga_hora)}</div>
    <table>
      <tr><td>Paciente</td><td><b>${h(s.paciente_nome)}</b></td><td>Nascimento</td><td>${fmtData(s.paciente_nascimento)}</td></tr>
      <tr><td>CPF</td><td>${fCPF(s.paciente_cpf)}</td><td>Cartão SUS</td><td>${fCNS(s.paciente_cns)}</td></tr>
      <tr><td>Telefone</td><td>${fTel(s.paciente_telefone)}</td><td>Protocolo</td><td>${h(s.protocolo)}</td></tr>
      <tr><td>Procedimento</td><td colspan="3"><b>${h(s.procedimento_nome)}</b>${s.procedimento_codigo ? ' — SIGTAP '+h(s.procedimento_codigo) : ''}</td></tr>
      <tr><td>Local</td><td colspan="3"><b>${h(s.unidade_executante_nome)}</b>${s.unidade_executante_endereco ? ' — '+h(s.unidade_executante_endereco) : ''}${s.unidade_executante_telefone ? ' — Tel. '+fTel(s.unidade_executante_telefone) : ''}</td></tr>
      <tr><td>Profissional</td><td>${h(s.vaga_profissional||'—')}</td><td>Solicitante</td><td>${h(s.profissional_solicitante||'—')}${s.crm_solicitante ? ' ('+h(s.crm_solicitante)+')' : ''}</td></tr>
    </table>
    <div class="obs"><b>Orientações:</b> chegar com 30 minutos de antecedência, com documento com foto, Cartão SUS, esta guia,
      o pedido médico e exames anteriores. Se não puder comparecer, avise a Secretaria de Saúde com antecedência para que a vaga seja remanejada.</div>
    ${qr ? `<div class="acomp">
      <div class="qr">${qr}</div>
      <div><b>Acompanhe pelo celular</b>
        <div>Aponte a câmera para o código ao lado, ou acesse <span class="url">${h(acompanhar)}</span></div>
        <div>Será pedido o protocolo <b>${h(s.protocolo)}</b> e a data de nascimento do paciente.</div></div>
    </div>` : ''}
    <div class="ass"><div>Responsável pelo agendamento</div><div>Paciente / responsável</div></div>
    <div class="rod"><span>${nome}</span><span>Emitido em ${new Date().toLocaleString('pt-BR')}</span></div></div>`;
  w.document.write(`<!DOCTYPE html><html lang="pt-BR"><head><meta charset="utf-8"><title>Guia ${h(s.numero_guia)}</title>
  <style>body{font-family:Arial,sans-serif;max-width:760px;margin:16px auto;color:#111;font-size:12.5px}
  .cab{display:flex;justify-content:space-between;align-items:flex-end;border-bottom:3px solid #0b4f7c;padding-bottom:6px}
  .g{text-align:right;font-size:11px}.g b{font-size:24px;letter-spacing:.06em}
  .dest{font-size:17px;font-weight:bold;background:#eef4fa;border:1px solid #c5d9ea;padding:8px;border-radius:6px;text-align:center;margin:8px 0}
  table{width:100%;border-collapse:collapse}td{padding:3px 4px;vertical-align:top;border-bottom:1px solid #ddd}td:nth-child(odd){color:#444;width:90px}
  .obs{font-size:11px;color:#222;border:1px dashed #777;padding:6px;margin-top:8px}.ass{margin-top:30px;display:flex;gap:40px}
  .ass div{flex:1;border-top:1px solid #000;text-align:center;padding-top:3px;font-size:11px}
  .rod{display:flex;justify-content:space-between;font-size:10px;color:#555;margin-top:8px}
  .acomp{display:flex;gap:12px;align-items:center;margin-top:8px;border:1px solid #c5d9ea;background:#f7fbfe;padding:8px;border-radius:6px;font-size:10.5px}
  .acomp .qr{flex:none;line-height:0}
  .acomp .qr svg{width:120px;height:120px;display:block}
  .acomp .url{font-family:monospace;word-break:break-all}
  .corte{border-top:1px dashed #000;margin:18px 0;text-align:center;font-size:10px;color:#555}
  @media print{button{display:none}body{margin:0 auto}@page{size:A4 portrait;margin:10mm}}</style></head><body>
  ${via('Via do paciente')}<div class="corte">✂ recorte aqui</div>${via('Via do local de atendimento')}
  <p><button type="button" id="btn-imprimir">Imprimir</button></p></body></html>`);
  w.document.close();
  /* O botão e a impressão automática são ligados daqui, pela janela que
     abriu: a janela about:blank herda o CSP deste documento, então script
     inline dentro dela seria bloqueado. O atraso dá tempo de o logo carregar. */
  const btn = w.document.getElementById('btn-imprimir');
  if(btn) btn.onclick = () => w.print();
  setTimeout(() => { try { w.focus(); w.print(); } catch { /* janela fechada antes */ } }, 400);
}

/* =====================================================================
   CONFIRMAÇÃO DE ATENDIMENTO — pelo número da guia
   ===================================================================== */
async function pgConfirmacao(el){
  const P = params(), execs = locaisExec(), fixo = papel() === 'executante';
  if(fixo && !S.perfil.unidade_id){ el.innerHTML = estado({ tipo:'permissao', titulo:'Usuário sem local de atendimento', texto:'Peça ao administrador para vincular seu usuário ao local que confirma as guias.' }); return; }
  const localPadrao = fixo ? S.perfil.unidade_id : (execs.find(u => u.id === S.perfil.unidade_id)?.id || '');
  el.innerHTML = `
    <section class="card" aria-labelledby="g-t">
      <h2 id="g-t" style="font-size:17px">Buscar guia</h2>
      <form id="g-f" class="guia-busca" role="search">
        <div class="field"><label for="g-num">Número da guia</label><span class="dica" id="g-num-d">Está no alto da guia do paciente, ex.: 26000015</span>
          <input id="g-num" data-mask="guia" inputmode="numeric" autocomplete="off" aria-describedby="g-num-d" value="${h(P.get('guia') || '')}"></div>
        <button class="btn pri lg" type="submit">Buscar</button>
      </form>
      <div id="g-res" aria-live="polite"></div>
    </section>
    <section class="card" aria-labelledby="d-t">
      <div class="card-h"><h2 id="d-t">Atendimentos</h2><span class="spacer"></span><span class="sub" id="d-resumo" aria-live="polite"></span></div>
      <div class="filtros">
        <div class="field"><label for="d-modo">Mostrar</label><select id="d-modo"><option value="dia">Agenda do dia</option><option value="pend" ${P.get('pend')?'selected':''}>Aguardando confirmação (até hoje)</option></select></div>
        <div class="field"><label for="d-local">Local</label><select id="d-local" ${fixo?'disabled':''}>${optList(execs, localPadrao, fixo ? null : 'Todos os locais')}</select></div>
        <div class="field" id="d-data-w"><label for="d-data">Data</label><input type="date" id="d-data" value="${hojeISO()}"></div>
        <div class="field" id="d-nav-w"><span class="lbl" aria-hidden="true">&nbsp;</span><div class="row"><button type="button" class="btn sm" id="d-ant" aria-label="Dia anterior">‹ Anterior</button><button type="button" class="btn sm" id="d-hoje">Hoje</button><button type="button" class="btn sm" id="d-prox" aria-label="Próximo dia">Próximo ›</button></div></div>
        <div class="field cresce"><label for="d-txt">Filtrar lista</label><input type="search" id="d-txt" placeholder="Nome ou nº da guia"></div>
        <div class="field"><label for="d-st">Situação</label><select id="d-st"><option value="">Todas</option><option value="agendada">A confirmar</option><option value="realizada">Realizadas</option><option value="faltou">Faltas</option></select></div>
      </div>
      <div id="d-lista"></div>
    </section>`;

  /* registro com resumo e observação */
  const registrar = async (s, status, btn) => {
    const real = status === 'realizada';
    const r = await confirmar({ titulo: real ? 'Confirmar execução' : 'Registrar falta', botao: real ? 'Confirmar execução' : 'Registrar falta', cls: real ? 'ok' : 'err',
      html:`<dl class="dl"><div><dt>Guia</dt><dd><b>${h(s.numero_guia)}</b></dd></div><div><dt>Paciente</dt><dd>${h(s.paciente_nome)}</dd></div>
        <div><dt>Procedimento</dt><dd>${h(s.procedimento_nome)}</dd></div><div><dt>Agendado para</dt><dd>${fmtData(s.vaga_data)} às ${fmtHora(s.vaga_hora)}</dd></div></dl>
        ${alerta(real ? 'info' : 'warn', real ? 'O atendimento será registrado como <b>realizado</b>. Isso encerra a solicitação.' : 'O paciente será registrado como <b>faltoso</b>. Isso encerra a solicitação; se ele ainda precisar do atendimento, será necessária nova solicitação.', 'O que acontece')}`,
      campo:{ label:'Observação', obrigatorio:false, dica: real ? 'Ex.: realizado sem intercorrências.' : 'Ex.: paciente avisou que não viria; sem contato.' } });
    if(!r.ok) return false;
    await ocupado(btn, () => q(sb.rpc('confirmar_atendimento', { p_guia:s.numero_guia, p_status:status, p_obs:r.texto || null })));
    aviso(`Guia <b>${h(s.numero_guia)}</b> — ${h(s.paciente_nome)}: ${real ? '<b>execução confirmada</b>' : '<b>falta registrada</b>'} em ${fmtDataHora(new Date())}.`, real ? 'ok' : 'warn', 'Registro concluído');
    atualizarContadores();
    return true;
  };

  /* busca da guia com mensagens distintas */
  const buscar = async (guia) => {
    guia = dig(guia ?? $('#g-num').value); const box = $('#g-res');
    if(!guia){ box.innerHTML = alerta('err', 'Digite o número da guia.'); $('#g-num').focus(); return; }
    $('#g-num').value = guia;
    box.innerHTML = carregando('Buscando guia…', true);
    const sit = await q(sb.rpc('consultar_guia', { p_guia:guia }));
    if(!sit.encontrada){ box.innerHTML = alerta('err', `Não existe guia com o número <b>${h(guia)}</b>. Confira os números na guia impressa. Se o paciente não tiver guia, procure a Central de Regulação.`, 'Guia não encontrada'); return; }
    if(sit.outro_local){ box.innerHTML = alerta('warn', `A guia <b>${h(guia)}</b> é de outro local de atendimento: <b>${h(sit.local_nome || '—')}</b>${sit.data ? `, em ${fmtData(sit.data)}` : ''}. Oriente o paciente a ir ao local indicado na guia.`, 'Guia de outro local'); return; }
    const s = await q(sb.from('vw_solicitacoes').select('*').eq('numero_guia', guia).maybeSingle());
    if(!s){ box.innerHTML = alerta('err', 'Seu perfil não tem acesso a esta guia.', 'Sem acesso'); return; }
    const fim = s.status !== 'agendada', futura = s.vaga_data > hojeISO();
    box.innerHTML = `<div class="res-guia ${s.status==='realizada'?'fim-ok':['faltou','cancelada'].includes(s.status)?'fim-err':''}">
      <div class="row"><div><div class="muted">Guia</div><div class="gnum">${h(s.numero_guia)}</div></div><span class="spacer"></span>${badgeSt(s)}</div>
      <dl class="dl" style="margin-top:12px">
        <div><dt>Paciente</dt><dd><b>${h(s.paciente_nome)}</b></dd></div>
        <div><dt>Nascimento</dt><dd>${fmtData(s.paciente_nascimento)} (${idade(s.paciente_nascimento)} anos)</dd></div>
        <div><dt>CPF</dt><dd>${fCPF(s.paciente_cpf)}</dd></div><div><dt>Cartão SUS</dt><dd>${fCNS(s.paciente_cns)}</dd></div>
        <div><dt>Procedimento</dt><dd>${h(s.procedimento_nome)}</dd></div><div><dt>Local</dt><dd>${h(s.unidade_executante_nome || '—')}</dd></div>
        <div><dt>Data e hora</dt><dd>${s.vaga_data ? `${dataExtenso(s.vaga_data)} às ${fmtHora(s.vaga_hora)}` : '—'}</dd></div><div><dt>Profissional</dt><dd>${h(s.vaga_profissional || '—')}</dd></div>
      </dl>
      ${s.status === 'cancelada' ? alerta('err', 'Esta solicitação foi cancelada. Não há atendimento a confirmar.', 'Guia cancelada')
        : fim ? alerta(s.status === 'realizada' ? 'ok' : 'err', `${h(STATUS[s.status])} registrada em ${fmtDataHora(s.data_execucao || s.updated_at)} por ${h(s.confirmado_por_nome || '—')}.${s.obs_execucao ? '<br>Observação: ' + h(s.obs_execucao) : ''} Não é possível registrar de novo.`, 'Guia já finalizada')
        : futura ? alerta('warn', `Este atendimento está marcado para <b>${dataExtenso(s.vaga_data)}</b>. A execução só pode ser confirmada a partir dessa data. Confira se o paciente veio no dia certo.`, 'Atendimento futuro')
        : ''}
      ${s.status === 'faltou' && pode('solicitacao') ? `<a class="btn" href="#/solicitacao?pac=${s.paciente_id}">Nova solicitação para este paciente</a>` : ''}
      ${!fim ? `<div class="acoes fim" style="margin-top:12px"><button type="button" class="btn err-sec lg" id="g-falta">✕ Registrar falta</button>
          <button type="button" class="btn ok lg" id="g-exec" ${futura ? 'disabled aria-describedby="g-fut"' : ''}>✓ Confirmar execução</button></div>
          ${futura ? '<p class="muted" id="g-fut" style="text-align:right">Confirmação de execução disponível na data do atendimento.</p>' : ''}` : ''}
    </div>`;
    if(!fim){
      const go = st => async e => { try { if(await registrar(s, st, e.currentTarget)){ buscar(s.numero_guia); carregarLista(); } } catch(er){ toast(er.message, 'err'); } };
      $('#g-exec').onclick = go('realizada'); $('#g-falta').onclick = go('faltou');
    }
  };
  $('#g-f').onsubmit = e => { e.preventDefault(); buscar(); };

  /* lista do dia / pendentes */
  let atual = [];
  async function carregarLista(){
    const modo = $('#d-modo').value, d = $('#d-data').value, loc = $('#d-local').value;
    $('#d-data-w').classList.toggle('hidden', modo !== 'dia'); $('#d-nav-w').classList.toggle('hidden', modo !== 'dia');
    let qb = sb.from('vw_solicitacoes').select('*');
    qb = modo === 'dia' ? qb.eq('vaga_data', d).in('status', ['agendada','realizada','faltou']) : qb.eq('status', 'agendada').lte('vaga_data', hojeISO());
    if(loc) qb = qb.eq('unidade_executante_id', loc);
    $('#d-lista').innerHTML = carregando('Carregando atendimentos…', true);
    atual = (await q(qb)).sort((a, b) => (a.vaga_data + a.vaga_hora).localeCompare(b.vaga_data + b.vaga_hora));
    mostrar();
  }
  function mostrar(){
    const t = $('#d-txt').value.trim().toLowerCase(), st = $('#d-st').value, modo = $('#d-modo').value;
    const l = atual.filter(s => (!st || s.status === st) && (!t || s.paciente_nome.toLowerCase().includes(t) || (s.numero_guia || '').includes(t)));
    const c = k => atual.filter(s => s.status === k).length;
    $('#d-resumo').textContent = modo === 'dia' ? `${dataExtenso($('#d-data').value)}: ${atual.length} agendados · ${c('realizada')} realizados · ${c('faltou')} faltas · ${c('agendada')} a confirmar`
      : `${atual.length} atendimento(s) agendados até hoje ainda sem registro`;
    const loc = $('#d-local').value;
    montarTabela($('#d-lista'), { linhas:l, rotuloItens:'atendimento(s)', ordem:null,
      vazio: estado({ titulo: modo === 'dia' ? 'Nenhum atendimento nesta data' : 'Nenhum atendimento aguardando confirmação', texto: t || st ? 'Ajuste o filtro.' : '' }),
      onClick: s => { buscar(s.numero_guia); $('#g-num').scrollIntoView({ block:'center', behavior:'smooth' }); },
      colunas:[
        ...(modo === 'pend' ? [{ l:'Data', f:s => fmtData(s.vaga_data), v:s => s.vaga_data }] : []),
        { l:'Hora', f:s => `<b>${fmtHora(s.vaga_hora)}</b>`, v:s => s.vaga_hora },
        { l:'Guia', f:s => h(s.numero_guia), v:s => s.numero_guia },
        { l:'Paciente', f:s => `${h(s.paciente_nome)}<small>${fTel(s.paciente_telefone)}</small>`, v:s => s.paciente_nome },
        { l:'Procedimento', f:s => h(s.procedimento_nome), v:s => s.procedimento_nome },
        ...(loc ? [] : [{ l:'Local', f:s => h(s.unidade_executante_nome), v:s => s.unidade_executante_nome }]),
        { l:'Situação', f:s => badgeSt(s), v:s => s.status },
        { l:'Ações', ml:'', ordenavel:false, cls:'nowrap', f:s => s.status === 'agendada' ? `<button type="button" class="btn sm ok" data-a="realizada" data-id="${s.id}" ${s.vaga_data > hojeISO() ? 'disabled title="Disponível na data do atendimento"' : ''}>✓ Realizado<span class="sr-only"> — ${h(s.paciente_nome)}</span></button>
          <button type="button" class="btn sm err-sec" data-a="faltou" data-id="${s.id}">✕ Falta<span class="sr-only"> — ${h(s.paciente_nome)}</span></button>` : '' },
      ] });
    $$('#d-lista [data-a]').forEach(b => b.onclick = async () => {
      const s = atual.find(x => x.id == b.dataset.id);
      try { if(await registrar(s, b.dataset.a, b)) carregarLista(); } catch(e){ toast(e.message, 'err'); }
    });
  }
  $('#d-modo').onchange = carregarLista; $('#d-local').onchange = carregarLista; $('#d-data').onchange = carregarLista;
  $('#d-ant').onclick = () => { $('#d-data').value = addDias($('#d-data').value, -1); carregarLista(); };
  $('#d-prox').onclick = () => { $('#d-data').value = addDias($('#d-data').value, 1); carregarLista(); };
  $('#d-hoje').onclick = () => { $('#d-data').value = hojeISO(); carregarLista(); };
  $('#d-txt').oninput = debounce(mostrar, 200); $('#d-st').onchange = mostrar;
  await carregarLista();
  if(P.get('guia')) buscar(P.get('guia')); else $('#g-num').focus();
}

/* ---------- feriados nacionais ---------- */
function pascoa(y){
  const a = y%19, b = Math.floor(y/100), c = y%100, d = Math.floor(b/4), e = b%4, f = Math.floor((b+8)/25), g = Math.floor((b-f+1)/3),
        hh = (19*a+b-d-g+15)%30, i = Math.floor(c/4), k = c%4, l = (32+2*e+2*i-hh-k)%7, m = Math.floor((a+11*hh+22*l)/451),
        mes = Math.floor((hh+l-7*m+114)/31), dia = ((hh+l-7*m+114)%31)+1;
  return `${y}-${String(mes).padStart(2,'0')}-${String(dia).padStart(2,'0')}`;
}
const FER_CACHE = {};
function feriado(iso){
  const ano = iso.slice(0,4);
  if(!FER_CACHE[ano]){
    const f = {}, p = pascoa(+ano);
    [['01-01','Confraternização'],['04-21','Tiradentes'],['05-01','Dia do Trabalho'],['09-07','Independência'],['10-12','N. Sra. Aparecida'],
     ['11-02','Finados'],['11-15','Proclamação da República'],['11-20','Consciência Negra'],['12-25','Natal']].forEach(([md, n]) => f[`${ano}-${md}`] = n);
    f[addDias(p,-48)] = 'Carnaval'; f[addDias(p,-47)] = 'Carnaval'; f[addDias(p,-2)] = 'Sexta-feira Santa'; f[addDias(p,60)] = 'Corpus Christi';
    FER_CACHE[ano] = f;
  }
  return FER_CACHE[ano][iso] || null;
}
const addMes = (ym, k) => { const d = new Date(ym+'-01T12:00'); d.setMonth(d.getMonth()+k); return d.toISOString().slice(0,7); };
const nomeMes = ym => { const t = new Date(ym+'-01T12:00').toLocaleDateString('pt-BR', { month:'long', year:'numeric' }); return t[0].toUpperCase() + t.slice(1); };
const diasNoMes = ym => new Date(+ym.slice(0,4), +ym.slice(5,7), 0).getDate();
const isoDe = (ym, d) => `${ym}-${String(d).padStart(2,'0')}`;
const minutos = t => (t || '0:0').split(':').reduce((a, b) => a*60 + +b, 0);

async function carregarProfs(){
  const l = await fetchAll(() => sb.from('vagas').select('profissional').order('id'), 20000);
  S.profs = [...new Set(l.map(x => x.profissional).filter(Boolean))].sort((a, b) => a.localeCompare(b));
}

/* ===================================================================
   AGENDAS E VAGAS — calendário do mês, semana e lista de vagas
   =================================================================== */
async function pgAgendas(el){ return abaVagas(el); }

const STV = { livre:'○ Livre', ocupada:'● Ocupada', bloqueada:'⊘ Bloqueada' };
async function abaVagas(el){
  const execs = locaisExec(), P = params();
  let vis = P.get('vis') || store.get('regula_agenda_vis') || 'cal', mes = hojeISO().slice(0,7), semIni = inicioSemana(hojeISO());
  await carregarProfs();
  acaoTopo('+ Cadastrar agenda', 'pri', () => gerarVagas(execs, recarregar, { unidade:+$('#v-uni').value || null, prof:$('#v-prof').value.trim() }));
  el.innerHTML = `<div class="filtros no-print">
      <div class="field"><span class="lbl" id="v-vis-l">Visualizar</span><div class="seg" id="v-vis" role="group" aria-labelledby="v-vis-l">
        <button type="button" data-v="cal">Mês</button><button type="button" data-v="semana">Semana</button><button type="button" data-v="lista">Lista de vagas</button></div></div>
      <div class="field"><label for="v-uni">Local</label><select id="v-uni">${optList(execs, '', 'Todos os locais')}</select></div>
      <div class="field"><label for="v-proc">Procedimento</label><select id="v-proc">${optList(S.procedimentos, '', 'Todos')}</select></div>
      <div class="field"><label for="v-prof">Profissional</label><input id="v-prof" list="v-dl-prof" placeholder="Nome do profissional"><datalist id="v-dl-prof">${S.profs.map(p => `<option value="${h(p)}">`).join('')}</datalist></div>
      <div class="field"><label for="v-st">Situação da vaga</label><select id="v-st"><option value="">Todas</option><option value="livre">${STV.livre}</option><option value="ocupada">${STV.ocupada}</option><option value="bloqueada">${STV.bloqueada}</option></select></div>
    </div>
    <div class="row no-print" id="v-nav-cal" style="margin-bottom:12px">
      <button type="button" class="btn sm" id="v-ant" aria-label="Período anterior">‹</button><b id="v-mes" style="min-width:200px;text-align:center;font-size:16px" aria-live="polite"></b><button type="button" class="btn sm" id="v-prox" aria-label="Próximo período">›</button>
      <button type="button" class="btn sm" id="v-hoje">Hoje</button></div>
    <div class="filtros no-print" id="v-nav-lista">
      <div class="field"><label for="v-de">De</label><input type="date" id="v-de" value="${hojeISO()}"></div>
      <div class="field"><label for="v-ate">Até</label><input type="date" id="v-ate" value="${addDias(hojeISO(), 30)}"></div>
    </div>
    <div class="kpis" id="v-kpis"></div>
    <div id="v-corpo"></div>`;

  async function recarregar(){ await carregarProfs(); $('#v-dl-prof').innerHTML = S.profs.map(p => `<option value="${h(p)}">`).join(''); carregar(); }

  async function carregar(){
    store.set('regula_agenda_vis', vis);
    $$('#v-vis button').forEach(b => b.setAttribute('aria-pressed', b.dataset.v === vis));
    $('#v-nav-cal').classList.toggle('hidden', vis === 'lista'); $('#v-nav-lista').classList.toggle('hidden', vis !== 'lista');
    const u = $('#v-uni').value, p = $('#v-proc').value, prof = safeLike($('#v-prof').value), st = $('#v-st').value;
    let de, ate;
    if(vis === 'cal'){ de = mes+'-01'; ate = isoDe(mes, diasNoMes(mes)); $('#v-mes').textContent = nomeMes(mes); }
    else if(vis === 'semana'){ de = semIni; ate = addDias(semIni, 6); $('#v-mes').textContent = `Semana de ${fmtData(de)} a ${fmtData(ate)}`; }
    else { de = $('#v-de').value; ate = $('#v-ate').value; }
    $('#v-corpo').innerHTML = carregando('Carregando agenda…');
    const lst = await fetchAll(() => {
      let qb = sb.from('vagas').select('*, solicitacoes(numero_guia, pacientes(nome))').order('data').order('hora').order('id');
      if(u) qb = qb.eq('unidade_executante_id', u); if(p) qb = qb.eq('procedimento_id', p); if(prof) qb = qb.ilike('profissional', `%${prof}%`);
      if(st) qb = qb.eq('status', st); if(de) qb = qb.gte('data', de); if(ate) qb = qb.lte('data', ate);
      return qb;
    }, 20000);
    const c = s => lst.filter(v => v.status === s).length;
    const dias = new Set(lst.map(v => v.data)).size;
    const per = vis === 'lista' ? `${fmtData(de)} a ${fmtData(ate)}` : vis === 'semana' ? `semana de ${fmtData(de)}` : nomeMes(mes);
    $('#v-kpis').innerHTML = `${kpi({ l:'Vagas no período', v:lst.length, s:`${per} · ${dias} dia(s) com atendimento` })}
      ${kpi({ l:'Livres', v:c('livre'), s:'podem ser agendadas', c:'verde' })}
      ${kpi({ l:'Ocupadas', v:c('ocupada'), s:`ocupação ${pct(c('ocupada'), lst.length - c('bloqueada'))} (sem contar bloqueadas)`, c:'azul' })}
      ${kpi({ l:'Bloqueadas', v:c('bloqueada'), s:'indisponíveis para agendamento', c:'teal' })}`;
    vis === 'cal' ? renderCal(lst) : vis === 'semana' ? renderSemana(lst) : renderLista(lst, de, ate);
  }

  const agrupar = lst => { const porDia = {};
    lst.forEach(v => { const k = [v.unidade_executante_id, v.procedimento_id, v.profissional || ''].join('|');
      const g = ((porDia[v.data] ||= {})[k] ||= { u:v.unidade_executante_id, p:v.procedimento_id, prof:v.profissional, tot:0, liv:0, ocu:0, blq:0, h1:v.hora, h2:v.hora });
      g.tot++; if(v.status === 'livre') g.liv++; if(v.status === 'ocupada') g.ocu++; if(v.status === 'bloqueada') g.blq++;
      if(v.hora < g.h1) g.h1 = v.hora; if(v.hora > g.h2) g.h2 = v.hora; });
    return porDia; };
  const abrirDia = d => { vis = 'lista'; $('#v-de').value = d; $('#v-ate').value = d; carregar(); };

  function renderCal(lst){
    const primeiro = new Date(mes+'-01T12:00').getDay(), n = diasNoMes(mes), hoje = hojeISO(), porDia = agrupar(lst);
    let cells = DIAS.map(d => `<div class="dow" aria-hidden="true">${d}</div>`).join('') + '<div class="vazio"></div>'.repeat(primeiro);
    for(let d = 1; d <= n; d++){
      const iso = isoDe(mes, d), fer = feriado(iso), dow = (primeiro + d - 1) % 7;
      const gs = Object.values(porDia[iso] || {}).sort((a, b) => a.h1.localeCompare(b.h1));
      const tot = gs.reduce((a, g) => a + g.tot, 0), liv = gs.reduce((a, g) => a + g.liv, 0);
      cells += `<button type="button" class="cal-d ${iso===hoje?'hoje':''} ${dow===0||dow===6?'fds':''} ${iso<hoje?'passado':''}" data-d="${iso}"
          aria-label="${dataExtenso(iso)}${fer ? ', feriado: ' + h(fer) : ''}: ${gs.length ? `${gs.length} agenda(s), ${liv} vaga(s) livre(s) de ${tot}` : 'sem agenda'}">
        <span class="cal-n">${d}${fer ? ` <small>${h(fer)}</small>` : ''}</span>
        ${gs.slice(0,3).map(g => `<span class="cal-ev ${g.liv===0?'cheio':''}" aria-hidden="true"><b><em>${g.liv}/${g.tot}</em>${h(g.prof || nomeProc(g.p))}</b><span>${h(g.prof ? nomeProc(g.p) : nomeUnidade(g.u))}</span></span>`).join('')}
        ${gs.length > 3 ? `<span class="cal-mais" aria-hidden="true">+${gs.length-3} agenda(s)</span>` : ''}
      </button>`;
    }
    $('#v-corpo').innerHTML = `<section class="card"><div class="cal big-cal">${cells}</div>
      <p class="muted" style="margin:10px 0 0">Cada bloco mostra profissional, procedimento e vagas <b>livres / total</b> (borda verde: há vaga livre; azul: lotado). Clique em um dia para ver as vagas, bloquear ou cadastrar agenda.</p></section>`;
    $$('.cal-d[data-d]', el).forEach(c => c.onclick = () => abrirDia(c.dataset.d));
  }

  function renderSemana(lst){
    const porDia = agrupar(lst), hoje = hojeISO();
    $('#v-corpo').innerHTML = `<div class="semana">${Array.from({ length:7 }, (_, i) => {
      const d = addDias(semIni, i), fer = feriado(d), gs = Object.values(porDia[d] || {}).sort((a, b) => a.h1.localeCompare(b.h1));
      return `<section class="col ${d===hoje?'hoje':''}" aria-label="${dataExtenso(d)}"><h3>${diaSemana(d)} ${fmtData(d).slice(0,5)}${fer ? `<small>${h(fer)}</small>` : ''}</h3>
        ${gs.length ? gs.map(g => `<button type="button" class="bl" data-d="${d}"><b>${fmtHora(g.h1)}${g.h2 !== g.h1 ? '–' + fmtHora(g.h2) : ''} · ${h(nomeProc(g.p))}</b>
          <span class="muted">${h(g.prof || 'Sem profissional')} · ${h(nomeUnidade(g.u))}</span>
          <span class="cont"><span class="badge st-livre">${STV.livre}: ${g.liv}</span><span class="badge st-ocupada">${STV.ocupada}: ${g.ocu}</span>${g.blq ? `<span class="badge st-bloqueada">${STV.bloqueada}: ${g.blq}</span>` : ''}</span></button>`).join('')
          : '<p class="vazio">Sem agenda</p>'}</section>`; }).join('')}</div>`;
    $$('.bl[data-d]', el).forEach(b => b.onclick = () => abrirDia(b.dataset.d));
  }

  function renderLista(lst, de, ate){
    const mostrar = lst.slice(0, 1500), umDia = de && de === ate;
    $('#v-corpo').innerHTML = `
      <div class="row" style="margin-bottom:8px">
        ${umDia ? `<b style="font-size:15px">${dataExtenso(de)}${feriado(de) ? ` <span class="badge st-faltou">Feriado: ${h(feriado(de))}</span>` : ''}</b>
          <button type="button" class="btn sm" id="v-d-ant">‹ Dia anterior</button><button type="button" class="btn sm" id="v-d-prox">Próximo dia ›</button>
          ${de >= hojeISO() ? `<button type="button" class="btn sm pri" id="v-cad-dia">+ Cadastrar agenda neste dia</button>` : ''}` : ''}
        <span class="spacer"></span><span class="muted" id="v-sel-n" aria-live="polite"></span>
        <button type="button" class="btn sm" id="v-bloq">Bloquear</button><button type="button" class="btn sm" id="v-lib">Liberar</button><button type="button" class="btn sm err-sec" id="v-del">Excluir</button>
      </div>
      ${lst.length ? `${lst.length > 1500 ? '<p class="muted">Mostrando as primeiras 1500 vagas — refine os filtros.</p>' : ''}<div class="tbl-wrap"><table class="resp">
      <thead><tr><th scope="col"><input type="checkbox" id="v-all" aria-label="Selecionar todas as vagas livres e bloqueadas"></th><th scope="col">Data</th><th scope="col">Hora</th><th scope="col">Local</th><th scope="col">Procedimento</th><th scope="col">Profissional</th><th scope="col">Situação</th><th scope="col">Paciente</th></tr></thead><tbody>
      ${mostrar.map(v => { const sol = (v.solicitacoes||[])[0];
        return `<tr><td data-label="">${v.status!=='ocupada' ? `<label class="chk"><input type="checkbox" class="v-ck" value="${v.id}" aria-label="Selecionar vaga de ${fmtData(v.data)} às ${fmtHora(v.hora)}"><span class="sr-only">Selecionar</span></label>` : '<span class="muted" title="Vaga ocupada: remarque ou cancele pelo agendamento">—</span>'}</td>
        <td data-label="Data">${diaSemana(v.data)} ${fmtData(v.data)}</td><td data-label="Hora">${fmtHora(v.hora)}</td><td data-label="Local">${h(nomeUnidade(v.unidade_executante_id))}</td>
        <td data-label="Procedimento">${h(nomeProc(v.procedimento_id))}</td><td data-label="Profissional">${h(v.profissional||'—')}</td><td data-label="Situação">${badgeSt(v.status)}</td>
        <td data-label="Paciente">${sol ? `${h(sol.pacientes?.nome)}<small>Guia ${h(sol.numero_guia||'')}</small>` : '—'}</td></tr>`; }).join('')}
      </tbody></table></div>` : estado({ titulo:`Nenhuma vaga ${umDia ? 'neste dia' : 'no período'}`, texto: pode('agendas') ? 'Use <b>+ Cadastrar agenda</b> para criar vagas.' : '' })}`;
    const atualizaSel = () => { $('#v-sel-n').textContent = `${$$('.v-ck:checked', el).length} vaga(s) selecionada(s)`; };
    const all = $('#v-all'); if(all) all.onchange = () => { $$('.v-ck', el).forEach(c => c.checked = all.checked); atualizaSel(); };
    $$('.v-ck', el).forEach(c => c.onchange = atualizaSel); atualizaSel();
    $('#v-bloq').onclick = e => emLote('bloq', e.currentTarget); $('#v-lib').onclick = e => emLote('lib', e.currentTarget); $('#v-del').onclick = e => emLote('del', e.currentTarget);
    if(umDia){
      $('#v-d-ant').onclick = () => { $('#v-de').value = $('#v-ate').value = addDias(de, -1); carregar(); };
      $('#v-d-prox').onclick = () => { $('#v-de').value = $('#v-ate').value = addDias(de, 1); carregar(); };
      const cd = $('#v-cad-dia'); if(cd) cd.onclick = () => gerarVagas(execs, recarregar, { unidade:+$('#v-uni').value || null, prof:$('#v-prof').value.trim(), datas:[de] });
    }
  }

  const emLote = async (acao, btn) => {
    const ids = $$('.v-ck:checked', el).map(c => +c.value);
    if(!ids.length) return toast('Marque as vagas na lista antes de escolher a ação.', 'err');
    const txt = { bloq:['Bloquear vagas', 'As vagas ficam indisponíveis para agendamento até serem liberadas.', 'warn', 'Bloquear'],
                  lib:['Liberar vagas', 'As vagas voltam a ficar disponíveis para agendamento.', 'pri', 'Liberar'],
                  del:['Excluir vagas', 'As vagas serão apagadas da agenda. Esta ação não pode ser desfeita. Vagas ocupadas não são afetadas.', 'err', 'Excluir'] }[acao];
    const r = await confirmar({ titulo:txt[0], botao:`${txt[3]} ${ids.length} vaga(s)`, cls:txt[2], html:`<p>${ids.length} vaga(s) selecionada(s).</p>` + alerta(acao === 'del' ? 'warn' : 'info', txt[1], 'O que acontece') });
    if(!r.ok) return;
    try {
      await ocupado(btn, async () => {
        if(acao === 'del') await q(sb.from('vagas').delete().in('id', ids).neq('status','ocupada'));
        else await q(sb.from('vagas').update({ status: acao==='bloq' ? 'bloqueada' : 'livre' }).in('id', ids).neq('status','ocupada'));
      });
      aviso(`${ids.length} vaga(s) ${{ bloq:'bloqueada(s)', lib:'liberada(s)', del:'excluída(s)' }[acao]}.`, 'ok'); carregar();
    } catch(e){ toast(e.message, 'err'); }
  };

  $$('#v-vis button').forEach(b => b.onclick = () => { vis = b.dataset.v; carregar(); });
  ['#v-uni','#v-proc','#v-st','#v-de','#v-ate'].forEach(s => $(s).onchange = carregar);
  $('#v-prof').oninput = debounce(carregar, 400);
  $('#v-ant').onclick = () => { if(vis === 'semana') semIni = addDias(semIni, -7); else mes = addMes(mes, -1); carregar(); };
  $('#v-prox').onclick = () => { if(vis === 'semana') semIni = addDias(semIni, 7); else mes = addMes(mes, 1); carregar(); };
  $('#v-hoje').onclick = () => { mes = hojeISO().slice(0,7); semIni = inicioSemana(hojeISO()); carregar(); };
  await carregar();
}
function inicioSemana(iso){ const d = new Date(iso+'T12:00'); return addDias(iso, -d.getDay()); }

/* ===================================================================
   4b. CADASTRAR AGENDA
   Dias específicos (calendário) · toda semana / quinzenal · todo mês
   Vários turnos por dia · horário marcado ou ordem de chegada
   =================================================================== */
function gerarVagas(execs, depois, pre={}){
  if(!execs.length) return toast('Cadastre primeiro um local de atendimento (aba "Locais de atendimento").', 'err');
  const hoje = hojeISO();
  const st = {
    modo: 'avulsas', avulsas: new Set(pre.datas || []), removidas: new Set(), existentes: new Set(),
    mesCal: (pre.datas?.[0] || hoje).slice(0,7),
    dias: [1], cada: 1, di: hoje, df: addDias(hoje, 90),
    mtipo: 'nth', nth: 1, ndow: 1, dia: 15, mini: hoje.slice(0,7), mqtd: 6,
    turnos: [{ tipo:'intervalo', ini:'07:00', fim:'11:00', int:20, qtd:1 }]
  };
  const meses = Array.from({ length:13 }, (_, i) => addMes(hoje.slice(0,7), i));

  const vagasTurno = t => {
    if(t.tipo === 'chegada') return Math.max(0, +t.qtd || 0);
    const a = minutos(t.ini), b = minutos(t.fim), it = +t.int || 0;
    return it >= 5 && b > a ? Math.ceil((b - a) / it) * Math.max(1, +t.qtd || 1) : 0;
  };
  const resumoTurno = t => t.tipo === 'chegada'
    ? `${+t.qtd || 0} vaga(s) às ${t.ini}`
    : (vagasTurno(t) ? `${Math.ceil((minutos(t.fim) - minutos(t.ini)) / t.int)} horário(s) × ${t.qtd} = <b>${vagasTurno(t)}</b> vagas` : '<span style="color:var(--err)">confira os horários</span>');

  modal({
    title: 'Cadastrar agenda', wide: true,
    body: `
      <div class="grid">
        <div class="field s2"><label for="g-uni">Local de atendimento *</label><select id="g-uni">${optList(execs, pre.unidade || execs[0].id)}</select></div>
        <div class="field s2"><label for="g-proc">Procedimento *</label><select id="g-proc"></select></div>
        <div class="field full"><label for="g-prof">Profissional</label><input id="g-prof" list="g-dl-prof" value="${h(pre.prof || '')}" placeholder="Ex.: Dr. Fulano de Tal — CRM-GO 0000">
          <datalist id="g-dl-prof">${(S.profs || []).map(p => `<option value="${h(p)}">`).join('')}</datalist></div>
      </div>
      <div class="sec-t">Quando o profissional atende?</div>
      <div class="seg" id="g-modo" role="group" aria-label="Forma de repetição">
        <button type="button" data-m="avulsas">Dias específicos</button>
        <button type="button" data-m="semanal">Toda semana / quinzenal</button>
        <button type="button" data-m="mensal">Uma vez por mês</button>
      </div>
      <div id="g-quando" style="margin-top:14px"></div>
      <label class="chk" id="g-fer-w" style="margin-top:10px"><input type="checkbox" id="g-fer" checked> Não criar vagas em feriados nacionais</label>
      <div class="sec-t">Horários de atendimento no dia</div>
      <div id="g-turnos"></div>
      <button type="button" class="btn sm" id="g-add">+ Adicionar turno (ex.: tarde)</button>
      <div class="sec-t">Resumo</div>
      <div id="g-prev"></div>`,
    onOpen: m => {
      const $m = s => $(s, m);

      /* ----- procedimentos do local + datas que já têm agenda ----- */
      const atualizaProcs = () => {
        const uid = +$m('#g-uni').value, ja = procsDoLocal(uid), outros = S.procedimentos.filter(p => p.ativo && !ja.includes(p));
        $m('#g-proc').innerHTML = (ja.length ? `<optgroup label="Realizados neste local">${optList(ja)}</optgroup>` : '')
          + `<optgroup label="${ja.length ? 'Outros procedimentos' : 'Procedimentos'}">${optList(outros)}</optgroup>`;
      };
      const carregarExist = async () => {
        const u = +$m('#g-uni').value, p = +$m('#g-proc').value, prof = $m('#g-prof').value.trim() || null;
        const l = await fetchAll(() => sb.from('vagas').select('data,profissional').eq('unidade_executante_id', u).eq('procedimento_id', p).gte('data', hoje).order('id'), 20000);
        st.existentes = new Set(l.filter(v => (v.profissional || null) === prof).map(v => v.data));
        if(st.modo === 'avulsas') renderQuando(); else prev();
      };

      /* ----- leitura dos campos da regra ----- */
      const lerQuando = () => {
        const g = s => $m(s);
        if(st.modo === 'semanal' && g('#g-cada')){
          st.dias = $$('.g-dia:checked', m).map(c => +c.value); st.cada = +g('#g-cada').value; st.di = g('#g-di').value; st.df = g('#g-df').value;
        }
        if(st.modo === 'mensal' && g('#g-mtipo')){
          st.mtipo = g('#g-mtipo').value; st.nth = +g('#g-nth').value; st.ndow = +g('#g-ndow').value; st.dia = +g('#g-dia').value || 1;
          st.mini = g('#g-mini').value; st.mqtd = +g('#g-mqtd').value;
          g('#g-nth-w').classList.toggle('hidden', st.mtipo !== 'nth'); g('#g-ndow-w').classList.toggle('hidden', st.mtipo !== 'nth');
          g('#g-dia-w').classList.toggle('hidden', st.mtipo !== 'dia');
        }
      };

      /* ----- cálculo das datas ----- */
      const calcular = () => {
        let ds = [];
        if(st.modo === 'avulsas') ds = [...st.avulsas];
        else if(st.modo === 'semanal'){
          if(st.di && st.df && st.di <= st.df && st.dias.length){
            const base = new Date(st.di+'T12:00'); base.setDate(base.getDate() - base.getDay());
            for(let d = st.di, i = 0; d <= st.df && i < 800; d = addDias(d, 1), i++){
              const dt = new Date(d+'T12:00'), semana = Math.floor((dt - base) / (7*864e5));
              if(semana % st.cada === 0 && st.dias.includes(dt.getDay())) ds.push(d);
            }
          }
        } else {
          for(let i = 0; i < st.mqtd; i++){
            const ym = addMes(st.mini, i), n = diasNoMes(ym);
            if(st.mtipo === 'dia'){ if(st.dia <= n) ds.push(isoDe(ym, st.dia)); continue; }
            if(st.nth < 5){
              const off = (st.ndow - new Date(ym+'-01T12:00').getDay() + 7) % 7, dia = 1 + off + (st.nth - 1)*7;
              if(dia <= n) ds.push(isoDe(ym, dia));
            } else {
              const ult = new Date(isoDe(ym, n)+'T12:00').getDay();
              ds.push(isoDe(ym, n - ((ult - st.ndow + 7) % 7)));
            }
          }
        }
        ds = [...new Set(ds)].filter(d => d >= hoje).sort();
        const pulaFer = st.modo !== 'avulsas' && $m('#g-fer').checked;
        const r = { validas:[], feriados:[], existentes:[], removidas:[] };
        ds.forEach(d => {
          if(pulaFer && feriado(d)) r.feriados.push(d);
          else if(st.modo !== 'avulsas' && st.removidas.has(d)) r.removidas.push(d);
          else if(st.existentes.has(d)) r.existentes.push(d);
          else r.validas.push(d);
        });
        return r;
      };

      /* ----- calendário para dias específicos ----- */
      const miniCal = () => {
        const ym = st.mesCal, primeiro = new Date(ym+'-01T12:00').getDay(), n = diasNoMes(ym);
        let cells = DIAS.map(d => `<div class="dow">${d}</div>`).join('') + '<span></span>'.repeat(primeiro);
        for(let d = 1; d <= n; d++){
          const iso = isoDe(ym, d), fer = feriado(iso);
          cells += `<button type="button" class="dia ${fer?'fer':''} ${st.existentes.has(iso)?'tem':''}" aria-pressed="${st.avulsas.has(iso)}" aria-label="${dataExtenso(iso)}${fer?', feriado':''}${st.existentes.has(iso)?', já tem agenda':''}" data-d="${iso}"
            ${iso < hoje ? 'disabled' : ''} title="${h([fer, st.existentes.has(iso) ? 'já tem agenda deste profissional' : ''].filter(Boolean).join(' · '))}">${d}</button>`;
        }
        return `<div class="cal-head"><button type="button" class="btn sm" data-mes="-1" ${ym <= hoje.slice(0,7) ? 'disabled' : ''}>‹</button>
          <b >${nomeMes(ym)}</b><button type="button" class="btn sm" data-mes="1">›</button></div><div class="cal">${cells}</div>`;
      };

      const renderQuando = () => {
        $$('#g-modo button', m).forEach(b => b.setAttribute('aria-pressed', b.dataset.m === st.modo));
        $m('#g-fer-w').classList.toggle('hidden', st.modo === 'avulsas');
        const box = $m('#g-quando');
        if(st.modo === 'avulsas'){
          box.innerHTML = `<div class="row" style="align-items:flex-start;gap:20px">
            <div class="mini">${miniCal()}</div>
            <div class="muted" style="flex:1;min-width:220px;line-height:1.6">
              Clique nos dias em que o profissional vem atender. Use <b>‹ ›</b> para trocar de mês — dá para marcar dias de vários meses de uma vez.<br>
              Ideal para quem vem <b>um dia no mês</b> ou em datas irregulares.
              <div class="legenda"><span><i class="leg-cor on"></i> selecionado</span><span><i class="leg-cor tem"></i> já tem agenda</span><span style="color:var(--err)"><b>vermelho</b> = feriado</span></div>
            </div></div>`;
          $$('.dia', box).forEach(b => b.onclick = () => { const d = b.dataset.d; st.avulsas.has(d) ? st.avulsas.delete(d) : st.avulsas.add(d); renderQuando(); });
          $$('[data-mes]', box).forEach(b => b.onclick = () => { st.mesCal = addMes(st.mesCal, +b.dataset.mes); renderQuando(); });
        } else if(st.modo === 'semanal'){
          box.innerHTML = `<div class="grid">
            <div class="field full"><span class="lbl">Dias da semana</span><div class="row" role="group" aria-label="Dias da semana">
              ${DIAS_LONGO.map((d, i) => `<label class="chk"><input type="checkbox" class="g-dia" value="${i}" ${st.dias.includes(i)?'checked':''}> ${d}</label>`).join('')}</div></div>
            <div class="field s2"><label for="g-cada">Frequência</label><select id="g-cada">
              ${[[1,'Toda semana'],[2,'A cada 2 semanas (quinzenal)'],[3,'A cada 3 semanas'],[4,'A cada 4 semanas']].map(([v,l]) => `<option value="${v}" ${st.cada===v?'selected':''}>${l}</option>`).join('')}</select></div>
            <div class="field"><label for="g-di">De</label><input type="date" id="g-di" value="${st.di}" min="${hoje}"></div>
            <div class="field"><label for="g-df">Até</label><input type="date" id="g-df" value="${st.df}" min="${hoje}"></div></div>`;
        } else {
          box.innerHTML = `<div class="grid">
            <div class="field s2"><label for="g-mtipo">Regra</label><select id="g-mtipo">
              <option value="nth" ${st.mtipo==='nth'?'selected':''}>Em um dia da semana do mês (ex.: 2ª terça-feira)</option>
              <option value="dia" ${st.mtipo==='dia'?'selected':''}>Em um dia fixo do mês (ex.: todo dia 15)</option></select></div>
            <div class="field" id="g-nth-w"><label for="g-nth">Qual</label><select id="g-nth">
              ${[[1,'1ª (primeira)'],[2,'2ª (segunda)'],[3,'3ª (terceira)'],[4,'4ª (quarta)'],[5,'Última']].map(([v,l]) => `<option value="${v}" ${st.nth===v?'selected':''}>${l}</option>`).join('')}</select></div>
            <div class="field" id="g-ndow-w"><label for="g-ndow">Dia da semana</label><select id="g-ndow">
              ${DIAS_LONGO.map((d, i) => `<option value="${i}" ${st.ndow===i?'selected':''}>${d}</option>`).join('')}</select></div>
            <div class="field hidden" id="g-dia-w"><label for="g-dia">Dia do mês</label><input type="number" id="g-dia" min="1" max="31" value="${st.dia}"></div>
            <div class="field s2"><label for="g-mini">A partir de</label><select id="g-mini">${meses.map(ym => `<option value="${ym}" ${st.mini===ym?'selected':''} >${nomeMes(ym)}</option>`).join('')}</select></div>
            <div class="field s2"><label for="g-mqtd">Durante</label><select id="g-mqtd">${[1,2,3,4,6,12].map(v => `<option value="${v}" ${st.mqtd===v?'selected':''}>${v} ${v>1?'meses':'mês'}</option>`).join('')}</select></div>
          </div>`;
        }
        $$('input,select', box).forEach(i => { i.onchange = prev; if(i.type !== 'checkbox') i.oninput = prev; });
        prev();
      };

      /* ----- turnos ----- */
      const renderTurnos = () => {
        $m('#g-turnos').innerHTML = st.turnos.map((t, i) => `<div class="turno" data-i="${i}">
          <div class="field"><span class="lbl" aria-hidden="true">Turno ${i+1}</span><select aria-label="Tipo de horário — turno ${i+1}" data-k="tipo">
            <option value="intervalo" ${t.tipo==='intervalo'?'selected':''}>Horário marcado</option>
            <option value="chegada" ${t.tipo==='chegada'?'selected':''}>Ordem de chegada</option></select></div>
          <div class="field"><span class="lbl" aria-hidden="true">${t.tipo==='chegada' ? 'Chegada às' : 'Início'}</span><input type="time" aria-label="${t.tipo==='chegada' ? 'Chegada às' : 'Início'} — turno ${i+1}" data-k="ini" value="${t.ini}"></div>
          ${t.tipo === 'intervalo'
            ? `<div class="field"><span class="lbl" aria-hidden="true">Fim</span><input type="time" aria-label="Fim — turno ${i+1}" data-k="fim" value="${t.fim}"></div>
               <div class="field"><span class="lbl" aria-hidden="true">A cada (min)</span><input type="number" aria-label="A cada (min) — turno ${i+1}" data-k="int" min="5" step="5" value="${t.int}"></div>
               <div class="field"><span class="lbl" aria-hidden="true">Vagas por horário</span><input type="number" aria-label="Vagas por horário — turno ${i+1}" data-k="qtd" min="1" max="50" value="${t.qtd}"></div>`
            : `<div class="field"><span class="lbl" aria-hidden="true">Nº de vagas (fichas)</span><input type="number" aria-label="Nº de vagas (fichas) — turno ${i+1}" data-k="qtd" min="1" max="200" value="${t.qtd}"></div><span></span><span></span>`}
          <div class="t-res">${resumoTurno(t)}</div>
          ${st.turnos.length > 1 ? `<button type="button" class="btn sm ghost" data-rm="${i}" title="Remover turno">✕</button>` : '<span></span>'}
        </div>`).join('');
        $$('.turno', m).forEach(row => {
          const t = st.turnos[+row.dataset.i];
          $$('[data-k]', row).forEach(inp => {
            const upd = () => {
              const k = inp.dataset.k; t[k] = ['int','qtd'].includes(k) ? +inp.value : inp.value;
              if(k === 'tipo'){ if(t.tipo === 'chegada') t.qtd = 10; else { t.qtd = 1; t.int = t.int || 20; } renderTurnos(); return; }
              $('.t-res', row).innerHTML = resumoTurno(t); prev();
            };
            inp.onchange = upd; if(inp.tagName === 'INPUT') inp.oninput = upd;
          });
          const rm = $('[data-rm]', row); if(rm) rm.onclick = () => { st.turnos.splice(+rm.dataset.rm, 1); renderTurnos(); };
        });
        prev();
      };
      $m('#g-add').onclick = () => {
        const ult = st.turnos[st.turnos.length - 1];
        st.turnos.push(minutos(ult.ini) < 12*60 ? { ...ult, ini:'13:00', fim:'17:00' } : { ...ult });
        renderTurnos();
      };

      /* ----- resumo ----- */
      const prev = () => {
        lerQuando();
        const r = calcular(), porDia = st.turnos.reduce((a, t) => a + vagasTurno(t), 0);
        const chip = (d, cls='', btn='') => `<span class="chip ${cls}">${diaSemana(d)} ${fmtData(d)}${btn}</span>`;
        $m('#g-prev').innerHTML = `
          <div class="alert ${r.validas.length && porDia ? 'info' : 'warn'}" style="font-size:15px">
            <b>${r.validas.length}</b> dia(s) × <b>${porDia}</b> vaga(s) por dia = <b>${r.validas.length * porDia}</b> vagas</div>
          ${r.validas.length ? `<div class="chips">${r.validas.map(d => chip(d, '', `<button type="button" data-rmd="${d}" title="Tirar esta data">×</button>`)).join('')}</div>`
            : `<p class="muted">Nenhuma data. ${st.modo === 'avulsas' ? 'Clique nos dias do calendário acima.' : 'Ajuste a regra acima.'}</p>`}
          ${r.existentes.length ? `<p class="muted" style="margin:12px 0 6px">Já têm agenda deste profissional neste local — <b>não serão duplicadas</b>:</p><div class="chips">${r.existentes.map(d => chip(d, 'warn')).join('')}</div>` : ''}
          ${r.feriados.length ? `<p class="muted" style="margin:12px 0 6px">Feriados ignorados:</p><div class="chips">${r.feriados.map(d => `<span class="chip off">${fmtData(d)} · ${h(feriado(d))}</span>`).join('')}</div>` : ''}
          ${r.removidas.length ? `<p class="muted" style="margin:12px 0 6px">Datas retiradas (clique para voltar):</p><div class="chips">${r.removidas.map(d => chip(d, 'off', `<button type="button" data-volta="${d}" title="Voltar esta data">↺</button>`)).join('')}</div>` : ''}`;
        $$('[data-rmd]', m).forEach(b => b.onclick = () => {
          if(st.modo === 'avulsas'){ st.avulsas.delete(b.dataset.rmd); renderQuando(); } else { st.removidas.add(b.dataset.rmd); prev(); }
        });
        $$('[data-volta]', m).forEach(b => b.onclick = () => { st.removidas.delete(b.dataset.volta); prev(); });
        st._ultimo = r;
      };

      $$('#g-modo button', m).forEach(b => b.onclick = () => { lerQuando(); st.modo = b.dataset.m; renderQuando(); });
      $m('#g-fer').onchange = prev;
      $m('#g-uni').onchange = () => { atualizaProcs(); carregarExist(); };
      $m('#g-proc').onchange = carregarExist;
      $m('#g-prof').oninput = debounce(carregarExist, 400);
      st.prev = prev; st.calcular = calcular;
      atualizaProcs(); renderTurnos(); renderQuando(); carregarExist();
    },
    actions: [{ label:'Cancelar' }, { label:'Criar agenda', cls:'pri', onClick: async m => {
      const r = st.calcular();
      if(!r.validas.length) throw new Error('Nenhuma data selecionada.');
      if(!st.turnos.every(t => vagasTurno(t) > 0)) throw new Error('Confira os horários: cada turno precisa gerar pelo menos uma vaga.');
      const faixas = st.turnos.map(t => [minutos(t.ini), t.tipo === 'chegada' ? minutos(t.ini) + 1 : minutos(t.fim)]).sort((a, b) => a[0] - b[0]);
      for(let i = 1; i < faixas.length; i++) if(faixas[i][0] < faixas[i-1][1]) throw new Error('Os turnos estão com horários sobrepostos.');
      const res = await q(sb.rpc('gerar_vagas', {
        p_unidade: +$('#g-uni', m).value, p_procedimento: +$('#g-proc', m).value, p_profissional: $('#g-prof', m).value,
        p_datas: r.validas,
        p_turnos: st.turnos.map(t => ({ hora_ini:t.ini, hora_fim:t.tipo === 'chegada' ? t.ini : t.fim, intervalo:t.tipo === 'chegada' ? 0 : +t.int, qtd:+t.qtd }))
      }));
      toast(`${res.vagas} vagas criadas em ${res.datas} dia(s)${res.ignoradas.length ? ` · ${res.ignoradas.length} dia(s) ignorado(s), já tinham agenda` : ''}.`, 'ok');
      await carregarRefs(); depois && depois();
    }}]
  });
}


/* =====================================================================
   CADASTROS — padrão único: busca, situação, ordenação, editar,
   ativar/desativar (preferido à exclusão: preserva o histórico).
   ===================================================================== */
const stAtivo = v => badgeSt(v ? 'ativo' : 'inativo');

function crud({ el, tabela, campos, colunas, ordem='nome', titulo, artigo='o', extra, novoPermitido=true, validar, efeitoDesativar='', proteger }){
  if(novoPermitido) acaoTopo(`+ Cadastrar ${titulo}`, 'pri', () => editar());
  el.innerHTML = `<form class="filtros no-print" role="search" data-sem-submit>
      <div class="field cresce"><label for="c-busca">Buscar</label><input type="search" id="c-busca" placeholder="Digite parte do nome ou código"></div>
      <div class="field"><label for="c-sit">Situação</label><select id="c-sit"><option value="ativos">Somente ativos</option><option value="inativos">Somente inativos</option><option value="">Todos</option></select></div>
    </form><div id="c-lista"></div>`;
  let dados = [];
  const pref = 'cd-' + tabela;
  function editar(item){
    modal({ title: (item ? `Editar ${titulo}` : `Cadastrar ${titulo}`), wide:true,
      body: `<p class="muted" style="margin-top:0">Campos sem a indicação "(opcional)" são obrigatórios.</p>` + formHtml(campos, item || { ativo:true }, pref) + (extra ? extra.html(item) : ''),
      onOpen: m => extra?.onOpen && extra.onOpen(m, item),
      actions:[{ label:'Cancelar' }, { label:'Salvar', cls:'pri', onClick: async m => {
        const d = readForm(m, campos, validar ? (o, err) => validar(o, err, item) : null);
        const r = item ? await q(sb.from(tabela).update(d).eq('id', item.id).select().single())
                       : await q(sb.from(tabela).insert(d).select().single());
        if(extra?.save) await extra.save(r.id, m);
        aviso(`Cadastro ${item ? 'atualizado' : 'criado'}: <b>${h(d.nome || '')}</b>.`, 'ok');
        await carregarRefs(); carregar();
      }}]});
  }
  async function alternar(item, btn){
    const ativar = !item.ativo;
    if(!ativar && proteger){ const msg = proteger(item); if(msg){ toast(msg, 'err'); return; } }
    const r = await confirmar({ titulo: ativar ? `Ativar ${titulo}` : `Desativar ${titulo}`, botao: ativar ? 'Ativar' : 'Desativar', cls: ativar ? 'pri' : 'warn',
      html:`<p><b>${h(item.nome)}</b></p>` + alerta(ativar ? 'info' : 'warn', ativar ? 'Volta a aparecer nas listas e pode ser usad' + artigo + ' novamente.' : `Deixa de aparecer para novos registros. ${efeitoDesativar} O histórico é mantido.`, 'O que acontece') });
    if(!r.ok) return;
    await ocupado(btn, () => q(sb.from(tabela).update({ ativo:ativar }).eq('id', item.id)));
    aviso(`Cadastro ${ativar ? 'ativado' : 'desativado'}: <b>${h(item.nome)}</b>.`, 'ok');
    await carregarRefs(); carregar();
  }
  const tab = montarTabela($('#c-lista', el), { linhas:[], rotuloItens:'registro(s)', ordem:{ i:0, asc:true },
    onClick: x => editar(x),
    vazio: estado({ titulo:'Nenhum registro encontrado', texto:'Ajuste a busca ou a situação.' }),
    colunas:[ ...colunas,
      { l:'Situação', f:d => stAtivo(d.ativo), v:d => d.ativo ? 0 : 1 },
      { l:'Ações', ml:'', ordenavel:false, cls:'nowrap', f:d => `<button type="button" class="btn sm" data-ed="${h(d.id)}">Editar<span class="sr-only"> ${h(d.nome)}</span></button>
        <button type="button" class="btn sm ${d.ativo ? 'warn' : ''}" data-tg="${h(d.id)}">${d.ativo ? 'Desativar' : 'Ativar'}<span class="sr-only"> ${h(d.nome)}</span></button>` } ] });
  function render(){
    const t = $('#c-busca').value.toLowerCase(), sit = $('#c-sit').value;
    tab.set(dados.filter(d => (!t || JSON.stringify(d).toLowerCase().includes(t)) && (!sit || (sit === 'ativos') === !!d.ativo)));
    $$('[data-ed]', el).forEach(b => b.onclick = () => editar(dados.find(d => String(d.id) === b.dataset.ed)));
    $$('[data-tg]', el).forEach(b => b.onclick = () => alternar(dados.find(d => String(d.id) === b.dataset.tg), b));
  }
  // reaplica os botões quando a tabela é redesenhada (ordenar / mostrar mais)
  new MutationObserver(() => {
    $$('[data-ed]:not([data-ok])', el).forEach(b => { b.dataset.ok = 1; b.onclick = () => editar(dados.find(d => String(d.id) === b.dataset.ed)); });
    $$('[data-tg]:not([data-ok])', el).forEach(b => { b.dataset.ok = 1; b.onclick = () => alternar(dados.find(d => String(d.id) === b.dataset.tg), b); });
  }).observe($('#c-lista', el), { childList:true, subtree:true });
  async function carregar(){ dados = tabela === 'procedimentos' ? S.procedimentos : await q(sb.from(tabela).select('*').order(ordem)); render(); }
  $('#c-busca').oninput = debounce(render, 200); $('#c-sit').onchange = render;
  return carregar();
}

/* ---------- Locais e unidades ---------- */
function pgLocais(el){
  return crud({ el, tabela:'unidades', titulo:'local ou unidade', artigo:'o',
    efeitoDesativar:'Não recebe novas agendas nem novos agendamentos; vagas já marcadas continuam valendo.',
    campos:[
      { name:'nome', label:'Nome', required:true, span:3 },
      { name:'cnes', label:'CNES', attrs:'inputmode="numeric" maxlength="7"', dica:'7 números' },
      { name:'tipo', label:'Tipo', type:'select', required:true, empty:false, options: opts(TIPOS_UNI), span:2, dica:'Local de atendimento = onde o paciente é atendido e a guia é confirmada.' },
      { name:'telefone', label:'Telefone', mask:'tel', dica:'Aparece na guia do paciente.' },
      { name:'ativo', label:'Situação', type:'checkbox', text:'Ativo' },
      { name:'endereco', label:'Endereço completo', span:4, dica:'Aparece na guia do paciente.' } ],
    validar:(o, err) => { if(o.cnes && !/^\d{7}$/.test(o.cnes)) err('cnes', 'CNES deve ter 7 números.'); },
    colunas:[ { l:'Nome', f:d => `<b>${h(d.nome)}</b>${d.endereco ? `<small>${h(d.endereco)}</small>` : ''}`, v:d => d.nome },
      { l:'Tipo', f:d => h(TIPOS_UNI[d.tipo]), v:d => d.tipo },
      { l:'CNES', f:d => d.cnes ? h(d.cnes) : '<span class="tag inc">sem CNES</span>', v:d => d.cnes || '' },
      { l:'Telefone', f:d => fTel(d.telefone), v:d => d.telefone || '' },
      { l:'Procedimentos realizados', f:d => { const l = procsDoLocal(d.id); return d.tipo === 'solicitante' ? '<span class="muted">não se aplica</span>'
          : l.length ? h(l.slice(0,3).map(p => p.nome).join(', ')) + (l.length > 3 ? ` <span class="muted">+${l.length-3}</span>` : '') : '<span class="tag inc">nenhum</span>'; }, v:d => procsDoLocal(d.id).length } ],
    extra: {
      html: item => { const ja = item ? procsDoLocal(item.id).map(p => p.id) : [];
        return `<fieldset style="border:0;padding:0;margin:16px 0 0"><legend class="secao-t" style="width:100%">Procedimentos realizados neste local</legend>
          <p class="muted" style="margin-top:0">Só para locais de atendimento. Define onde cada procedimento pode ser agendado.</p>
          <div class="chk-grid" style="display:grid;grid-template-columns:repeat(auto-fill,minmax(240px,1fr));gap:6px;max-height:260px;overflow:auto;border:1px solid var(--borda);border-radius:8px;padding:10px">
          ${S.procedimentos.filter(p => p.ativo || ja.includes(p.id)).map(p => `<label class="chk"><input type="checkbox" class="up-ck" value="${p.id}" ${ja.includes(p.id)?'checked':''}> ${h(p.nome)}</label>`).join('')}</div></fieldset>`; },
      save: async (id, m) => {
        const marcados = $$('.up-ck:checked', m).map(c => +c.value);
        await q(sb.from('unidade_procedimentos').delete().eq('unidade_id', id));
        if(marcados.length) await q(sb.from('unidade_procedimentos').insert(marcados.map(pid => ({ unidade_id:id, procedimento_id:pid }))));
      }
    }});
}

/* ---------- Procedimentos ---------- */
/* =====================================================================
   ENVIO AO MINISTÉRIO (MIRA) E AUDITORIA
   ===================================================================== */

async function pgMira(el){
  const [pend, lote] = await Promise.all([
    q(sb.rpc('mira_pendencias')),
    q(sb.rpc('mira_lote', { p_de:null, p_ate:null })),
  ]);
  const total = await q(sb.from('solicitacoes').select('id', { count:'exact', head:true }))
    .then(() => null).catch(() => null);

  el.innerHTML = `
    ${alerta('info',
      'A Portaria GM/MS nº 6.656/2025 tornou obrigatório o envio dos dados de Regulação Assistencial ao '
      + 'Ministério da Saúde, no formato MIRA, e usar sistema próprio não dispensa. '
      + '<b>Esta tela monta os dados e aponta o que falta; ela não transmite.</b> '
      + 'A transmissão usa o Guia de Implementação FHIR da RNDS e exige credenciamento do município — '
      + 'confirme com a coordenação de regulação antes de usar esta exportação para valer.',
      'O que esta tela faz e o que não faz')}

    <section class="card">
      <div class="card-h"><h2>O que ainda impede o envio</h2>
        <span class="sub">${pend.length ? 'corrija antes de exportar' : 'nada pendente'}</span></div>
      <div id="mira-pend"></div>
    </section>

    <section class="card">
      <div class="card-h"><h2>Lote pronto para envio</h2>
        <span class="sub"><b>${num(lote.length)}</b> solicitação(ões) com o cadastro completo</span>
        <span class="spacer"></span>
        <div class="acoes">
          <button class="btn" id="mira-csv" ${lote.length ? '' : 'disabled'}>Baixar CSV</button>
          <button class="btn pri" id="mira-json" ${lote.length ? '' : 'disabled'}>Baixar JSON</button>
        </div></div>
      <p class="muted">Os 16 elementos do Modelo de Informação da Regulação Assistencial, conforme o anexo
        da Portaria Conjunta SAES/SEIDIGI nº 3/2023.</p>
      <div id="mira-tab"></div>
    </section>`;

  if(pend.length){
    montarTabela($('#mira-pend', el), {
      linhas: pend, rotuloItens:'pendência(s)', pagina:20,
      colunas: [
        { l:'Problema', f:p => `<b>${h(p.problema)}</b>`, v:p => p.problema },
        { l:'Solicitações', n:true, f:p => num(p.solicitacoes), v:p => Number(p.solicitacoes) },
        { l:'Como resolver', f:p => h(p.como_resolver), v:p => p.como_resolver },
      ],
    });
  } else {
    $('#mira-pend', el).innerHTML = alerta('ok', 'Todas as solicitações têm CID-10, código SIGTAP, CNES e identificação do paciente.');
  }

  const CAB = ['Identificador','Status','Procedimento (SIGTAP)','Data da solicitação','Data de autorização',
    'Data da execução','Identificador do paciente','Tipo','CNES solicitante','CNES regulador','CNES executante',
    'CBO executante','Modalidade','Caráter','Motivo (CID-10)'];
  const linha = r => [r.identificador_registro, r.status_solicitacao, r.codigo_procedimento,
    fmtDataHora(r.data_solicitacao), fmtDataHora(r.data_autorizacao), fmtDataHora(r.data_execucao),
    r.identificador_paciente, r.tipo_identificador_paciente, r.cnes_solicitante, r.cnes_regulador,
    r.cnes_executante, r.cbo_executante, r.modalidade_assistencial, r.caracter_solicitacao, r.motivo_solicitacao];

  if(lote.length){
    montarTabela($('#mira-tab', el), {
      linhas: lote, rotuloItens:'registro(s)', pagina:25,
      colunas: [
        { l:'Identificador', f:r => `<b>${h(r.identificador_registro)}</b>`, v:r => r.identificador_registro },
        { l:'Status', f:r => h(r.status_solicitacao), v:r => r.status_solicitacao },
        { l:'SIGTAP', f:r => h(r.codigo_procedimento), v:r => r.codigo_procedimento },
        { l:'Paciente', f:r => `${h(r.identificador_paciente)}<small>${h(r.tipo_identificador_paciente?.toUpperCase() || '')}</small>`, v:r => r.identificador_paciente },
        { l:'CID-10', f:r => h(r.motivo_solicitacao), v:r => r.motivo_solicitacao },
        { l:'Caráter', f:r => h(r.caracter_solicitacao), v:r => r.caracter_solicitacao },
        { l:'Solicitada em', f:r => fmtDataHora(r.data_solicitacao), v:r => r.data_solicitacao },
      ],
    });
    $('#mira-csv', el).onclick = () => baixarCSV(`mira_${hojeISO()}`, CAB, lote.map(linha));
    $('#mira-json', el).onclick = () => {
      const txt = JSON.stringify(lote.map(({ solicitacao_id, atualizado_em, ...resto }) => resto), null, 2);
      const a = document.createElement('a');
      a.href = URL.createObjectURL(new Blob([txt], { type:'application/json' }));
      a.download = `mira_${hojeISO()}.json`;
      document.body.appendChild(a); a.click(); a.remove();
      setTimeout(() => URL.revokeObjectURL(a.href), 1000);
      toast('Arquivo JSON gerado.', 'ok');
    };
  } else {
    $('#mira-tab', el).innerHTML = estado({ titulo:'Nenhum registro completo ainda',
      texto:'Resolva as pendências acima para os registros entrarem no lote.' });
  }
}

async function pgAuditoria(el){
  const [alt, aces, ret] = await Promise.all([
    q(sb.from('historico_paciente').select('*, perfis(nome), pacientes(nome)').order('created_at', { ascending:false }).limit(300)),
    q(sb.from('acessos_paciente').select('*, perfis(nome), pacientes(nome)').order('created_at', { ascending:false }).limit(300)),
    q(sb.from('politica_retencao').select('*').order('tabela')),
  ]);
  el.innerHTML = `
    <section class="card">
      <div class="card-h"><h2>Alterações em cadastro de paciente</h2>
        <span class="sub">300 mais recentes</span></div>
      <div id="aud-alt"></div>
    </section>
    <section class="card">
      <div class="card-h"><h2>Acessos a cadastro de paciente</h2>
        <span class="sub">300 mais recentes</span></div>
      <p class="muted">Registra abertura de cadastro pela aplicação — ficha, detalhe de solicitação e
        impressão de guia. Acessos repetidos pelo mesmo usuário em 10 minutos contam como um.</p>
      <div id="aud-ace"></div>
    </section>
    <section class="card">
      <div class="card-h"><h2>Retenção</h2></div>
      <p class="muted">Vale só para log operacional. Solicitação, histórico e cadastro de paciente são
        registro assistencial e <b>nunca</b> são apagados por aqui.</p>
      <div id="aud-ret"></div>
      <div class="acoes" style="margin-top:12px"><button class="btn" id="aud-limpar">Aplicar retenção agora</button></div>
    </section>`;

  montarTabela($('#aud-alt', el), { linhas:alt, rotuloItens:'alteração(ões)', pagina:25,
    vazio:'Nenhuma alteração registrada.',
    colunas:[
      { l:'Quando', f:r => fmtDataHora(r.created_at), v:r => r.created_at },
      { l:'Paciente', f:r => h(r.pacientes?.nome || `#${r.paciente_id}`), v:r => r.pacientes?.nome || '' },
      { l:'Campo', f:r => r.campo ? h(r.campo) : `<span class="tag inc">${h(r.operacao)}</span>`, v:r => r.campo || r.operacao },
      { l:'De', f:r => h(r.valor_anterior ?? '—'), v:r => r.valor_anterior || '' },
      { l:'Para', f:r => h(r.valor_novo ?? '—'), v:r => r.valor_novo || '' },
      { l:'Quem', f:r => h(r.perfis?.nome || '—'), v:r => r.perfis?.nome || '' },
    ] });

  montarTabela($('#aud-ace', el), { linhas:aces, rotuloItens:'acesso(s)', pagina:25,
    vazio:'Nenhum acesso registrado.',
    colunas:[
      { l:'Quando', f:r => fmtDataHora(r.created_at), v:r => r.created_at },
      { l:'Paciente', f:r => h(r.pacientes?.nome || `#${r.paciente_id}`), v:r => r.pacientes?.nome || '' },
      { l:'Quem', f:r => h(r.perfis?.nome || '—'), v:r => r.perfis?.nome || '' },
      { l:'Onde', f:r => h(r.contexto || '—'), v:r => r.contexto || '' },
    ] });

  montarTabela($('#aud-ret', el), { linhas:ret, rotuloItens:'regra(s)', ordem:null,
    colunas:[
      { l:'Tabela', f:r => `<b>${h(r.tabela)}</b>`, v:r => r.tabela },
      { l:'Guardar por', n:true, f:r => `${num(r.dias)} dia(s)`, v:r => r.dias },
      { l:'Por quê', f:r => h(r.descricao || '—'), v:r => r.descricao || '' },
    ] });

  $('#aud-limpar', el).onclick = async e => {
    const r = await confirmar({ titulo:'Aplicar retenção', botao:'Aplicar', cls:'warn',
      html: alerta('warn', 'Apaga definitivamente os registros de log que passaram do prazo da tabela acima. '
        + 'Nenhuma solicitação, histórico ou cadastro de paciente é tocado.', 'O que acontece') });
    if(!r.ok) return;
    const linhas = await ocupado(e.target, () => q(sb.rpc('aplicar_retencao')));
    const n = linhas.reduce((a, l) => a + Number(l.apagados), 0);
    aviso(n ? `${num(n)} registro(s) de log apagados.` : 'Nada estava fora do prazo.', 'ok');
    navegar();
  };
}

function pgVulnerabilidade(el){
  el.innerHTML = alerta('info',
    'A Política Nacional de Regulação manda a prioridade considerar risco, tempo de espera e '
    + '<b>vulnerabilidade</b>, e atribui ao município definir os critérios a partir da sua realidade '
    + 'epidemiológica, social e geográfica. Por isso esta lista nasce vazia: nenhum critério vem de fábrica. '
    + 'Enquanto não houver critério cadastrado, nada muda na ordenação da fila. O peso soma na análise '
    + 'regulatória; ele não passa por cima da classificação de risco.',
    'Quem define é a regulação municipal') + '<div id="crud"></div>';
  return crud({ el: $('#crud', el), tabela:'criterios_vulnerabilidade', titulo:'critério', artigo:'o',
    efeitoDesativar:'Deixa de somar peso nas novas análises; o que já foi registrado nas solicitações é mantido.',
    campos:[
      { name:'nome', label:'Critério', required:true, span:2, dica:'Ex.: pessoa em situação de rua; residente em área rural de difícil acesso' },
      { name:'peso', label:'Peso', type:'number', num:true, required:true, dica:'De 1 a 10. Quanto maior, mais a solicitação sobe entre as de mesmo risco.' },
      { name:'ativo', label:'Situação', type:'checkbox', text:'Ativo' },
      { name:'descricao', label:'Como identificar', span:4, rows:2,
        dica:'Opcional. Orienta quem registra, para o critério ser aplicado igual por todas as unidades.' } ],
    validar:(o, err) => { if(o.peso != null && (o.peso < 1 || o.peso > 10)) err('peso', 'O peso vai de 1 a 10.'); },
    colunas:[
      { l:'Critério', f:d => `<b>${h(d.nome)}</b>${d.descricao ? `<small>${h(d.descricao)}</small>` : ''}`, v:d => d.nome },
      { l:'Peso', n:true, f:d => num(d.peso), v:d => d.peso } ] });
}

function pgProcedimentos(el){
  el.innerHTML = alerta('info', 'A tabela SIGTAP importada está em <b>Situação → Somente inativos</b>. Busque pelo código ou nome, edite o tipo e a regulação, e ative apenas os procedimentos oferecidos pelo município.') + '<div id="crud"></div>';
  return crud({ el: $('#crud', el), tabela:'procedimentos', titulo:'procedimento', artigo:'o',
    efeitoDesativar:'Não aparece em novas solicitações nem em novas agendas; solicitações já registradas continuam.',
    campos:[
      { name:'nome', label:'Nome', required:true, span:3 },
      { name:'codigo_sigtap', label:'Código SIGTAP', attrs:'inputmode="numeric" maxlength="10"', dica:'10 números, conforme a tabela SIGTAP' },
      { name:'tipo', label:'Tipo', type:'select', required:true, empty:false, options: opts(TIPOS_PROC) },
      { name:'especialidade', label:'Especialidade', span:2 },
      { name:'ativo', label:'Situação', type:'checkbox', text:'Ativo' },
      { name:'exige_regulacao', label:'Regulação', type:'checkbox', text:'Exige análise do regulador antes do agendamento', span:4,
        dica:'Quando marcado, as solicitações deste procedimento que ainda não foram agendadas passam a aguardar a Análise regulatória. Desmarcado, vão direto para o agendamento.' } ],
    validar:(o, err) => { if(o.codigo_sigtap && !/^\d{10}$/.test(o.codigo_sigtap)) err('codigo_sigtap', 'O código SIGTAP tem 10 números.'); },
    colunas:[ { l:'Nome', f:d => `<b>${h(d.nome)}</b>`, v:d => d.nome },
      { l:'SIGTAP', f:d => d.codigo_sigtap ? h(d.codigo_sigtap) : '<span class="tag inc">sem código</span>', v:d => d.codigo_sigtap || '' },
      { l:'Tipo', f:d => h(TIPOS_PROC[d.tipo]), v:d => d.tipo }, { l:'Especialidade', f:d => h(d.especialidade || '—'), v:d => d.especialidade || '' },
      { l:'Regulação', f:d => d.exige_regulacao ? tagReg() : '<span class="muted">Direto para agendamento</span>', v:d => d.exige_regulacao ? 0 : 1 },
      { l:'Locais que realizam', f:d => { const ids = S.unProc.filter(x => x.procedimento_id === d.id).map(x => x.unidade_id);
          return ids.length ? h(ids.map(nomeUnidade).join(', ')) : '<span class="tag inc">nenhum</span>'; }, v:d => S.unProc.filter(x => x.procedimento_id === d.id).length } ] });
}

/* ---------- Pacientes ---------- */
async function pgPacientes(el){
  if(pode('solicitacao') || can('admin','agendador','regulador')) acaoTopo('+ Cadastrar paciente', 'pri', () => abrirPaciente(null, p => { carregar(); fichaPaciente(p.id); }));
  el.innerHTML = `<form class="filtros no-print" role="search" data-sem-submit><div class="field cresce"><label for="pc-busca">Buscar paciente</label>
    <input type="search" id="pc-busca" placeholder="Nome, CPF ou Cartão SUS"></div></form><div id="pc-lista"></div>`;
  const tab = montarTabela($('#pc-lista', el), { linhas:[], rotuloItens:'paciente(s)', ordem:{ i:0, asc:true },
    onClick: p => fichaPaciente(p.id),
    vazio: estado({ titulo:'Nenhum paciente encontrado', texto:'Confira a grafia ou busque pelo CPF ou Cartão SUS.' }),
    colunas:[
      { l:'Nome', f:p => `<b>${h(p.nome)}</b><small>Mãe: ${h(p.nome_mae || '—')}</small>`, v:p => p.nome },
      { l:'Nascimento', f:p => `${fmtData(p.data_nascimento)}<small>${idade(p.data_nascimento)} anos</small>`, v:p => p.data_nascimento },
      { l:'CPF', f:p => cpfOculto(p.cpf), v:p => p.cpf || '' },
      { l:'Cartão SUS', f:p => cnsOculto(p.cns), v:p => p.cns || '' },
      { l:'Contato', f:p => fTel(p.telefone), v:p => p.telefone || '' },
      { l:'Bairro', f:p => h(p.bairro || '—'), v:p => p.bairro || '' },
      { l:'Ações', ml:'', ordenavel:false, cls:'nowrap', f:p => `<button type="button" class="btn sm" data-ficha="${p.id}">Ficha<span class="sr-only"> de ${h(p.nome)}</span></button>
        ${pode('solicitacao') ? `<a class="btn sm pri" href="#/solicitacao?pac=${p.id}">Nova solicitação<span class="sr-only"> para ${h(p.nome)}</span></a>` : ''}` } ] });
  new MutationObserver(() => $$('[data-ficha]:not([data-ok])', el).forEach(b => { b.dataset.ok = 1; b.onclick = () => fichaPaciente(+b.dataset.ficha); }))
    .observe($('#pc-lista', el), { childList:true, subtree:true });
  async function carregar(){ tab.set(await buscarPacientes($('#pc-busca').value, 1000)); }
  $('#pc-busca').oninput = debounce(carregar);
  await carregar();
}

/* ---------- Usuários ---------- */
async function pgUsuarios(el){
  el.innerHTML = alerta('info','Crie a conta no Supabase Auth e depois libere o perfil e a unidade nesta tela. Para novas contas, selecione Somente inativos.') + '<div id="crud"></div>';
  return crud({ el: $('#crud', el), tabela:'perfis', novoPermitido:false, titulo:'usuário', artigo:'o', ordem:'nome',
    efeitoDesativar:'A pessoa não consegue mais entrar no sistema.',
    proteger: u => u.id === S.perfil.id ? 'Você não pode desativar o seu próprio usuário.' : '',
    campos:[
      { name:'nome', label:'Nome', required:true, span:2 },
      { name:'papel', label:'Perfil de acesso', type:'select', required:true, empty:false, options: opts(PAPEIS), span:2 },
      { name:'unidade_id', label:'Unidade vinculada', type:'select', num:true, span:2, options: () => S.unidades.map(u => ({ value:u.id, label:u.nome })) },
      { name:'ativo', label:'Situação', type:'checkbox', text:'Acesso ativo' } ],
    validar:(o, err) => {
      if(['solicitante','executante'].includes(o.papel) && !o.unidade_id) err('unidade_id', `O perfil ${PAPEIS[o.papel]} precisa de uma unidade vinculada.`);
      if(o.papel === 'executante' && o.unidade_id && S.unidades.find(u => u.id === o.unidade_id)?.tipo === 'solicitante') err('unidade_id', 'Para Local de atendimento, escolha uma unidade do tipo local de atendimento.');
      if(o.email && !/^\S+@\S+\.\S+$/.test(o.email)) err('email', 'E-mail inválido. Use o formato nome@dominio.');
    },
    colunas:[ { l:'Nome', f:d => `<b>${h(d.nome)}</b>${d.id === S.perfil.id ? ' <span class="tag">você</span>' : ''}`, v:d => d.nome },
      { l:'E-mail', f:d => h(d.email || '—'), v:d => d.email || '' },
      { l:'Perfil', f:d => h(PAPEIS[d.papel]), v:d => d.papel },
      { l:'Unidade', f:d => d.unidade_id ? h(nomeUnidade(d.unidade_id)) : (d.papel === 'admin' ? '<span class="muted">todas</span>' : '<span class="tag inc">sem unidade</span>'), v:d => nomeUnidade(d.unidade_id) } ] });
}

/* =====================================================================
   RELATÓRIOS — mesmos relatórios da versão anterior, com período
   explícito, explicação de cada cálculo, CSV e impressão.
   ===================================================================== */
const REL = {};
function baixarCSV(nome, cab, linhas){
  const esc = v => { v = v == null ? '' : String(v); return /[;"\n]/.test(v) ? '"' + v.replace(/"/g, '""') + '"' : v; };
  const txt = '﻿' + [cab, ...linhas].map(l => l.map(esc).join(';')).join('\r\n');
  const a = document.createElement('a');
  a.href = URL.createObjectURL(new Blob([txt], { type:'text/csv;charset=utf-8' })); a.download = nome + '.csv';
  document.body.appendChild(a); a.click(); a.remove(); setTimeout(() => URL.revokeObjectURL(a.href), 1000);
  toast(`Arquivo ${nome}.csv gerado (abre no Excel).`, 'ok');
}
function tabelaRel(id, titulo, cab, linhas, total, numCols=[], comoCalc=''){
  REL[id] = { titulo, cab, linhas: total ? [...linhas, total] : linhas };
  const td = (v, i) => `<td class="${numCols.includes(i)?'n':''}" data-label="${h(cab[i])}">${h(v)}</td>`;
  return `<section class="card" aria-labelledby="rel-${id}"><div class="card-h"><h2 id="rel-${id}">${h(titulo)}</h2><span class="spacer"></span>
    <button type="button" class="btn sm no-print" data-csv="${id}">Exportar CSV<span class="sr-only"> — ${h(titulo)}</span></button></div>
    ${comoCalc ? `<details class="criterios no-print" style="margin:-4px 0 10px"><summary>Como é calculado</summary><p>${comoCalc}</p></details>` : ''}
    ${linhas.length ? `<div class="tbl-wrap"><table class="resp"><thead><tr>${cab.map((c,i) => `<th scope="col" class="${numCols.includes(i)?'n':''}">${h(c)}</th>`).join('')}</tr></thead>
    <tbody>${linhas.map(l => `<tr>${l.map(td).join('')}</tr>`).join('')}
    ${total ? `<tr class="tot">${total.map(td).join('')}</tr>` : ''}</tbody></table></div>` : `<p class="muted">Sem dados para os filtros escolhidos.</p>`}</section>`;
}

async function pgRelatorios(el){
  const hoje = hojeISO(), ini = inicioMes();
  const execs = locaisExec(), fixo = papel() === 'executante';
  acaoTopo('Imprimir', '', () => print());
  el.innerHTML = `<section class="card no-print" aria-labelledby="rf-t"><h2 id="rf-t" style="font-size:16px">Filtros</h2>
    <form class="filtros" id="r-f" style="margin:0">
      <div class="field"><label for="r-de">Período: de</label><input type="date" id="r-de" value="${ini}"></div>
      <div class="field"><label for="r-ate">até</label><input type="date" id="r-ate" value="${hoje}"></div>
      <div class="field"><label for="r-local">Local de atendimento</label><select id="r-local" ${fixo?'disabled':''}>${optList(execs, fixo ? S.perfil.unidade_id : '', fixo ? null : 'Todos os locais')}</select></div>
      <div class="field"><label for="r-proc">Procedimento</label><select id="r-proc">${optList(S.procedimentos, '', 'Todos')}</select></div>
      <div class="field"><label for="r-orig">Origem do pedido</label><select id="r-orig">${optList(S.unidades.filter(u => u.tipo !== 'executante'), '', 'Todas')}</select></div>
      <div class="field"><span class="lbl" aria-hidden="true">&nbsp;</span><div class="row">
        <button type="button" class="btn sm" data-per="mes">Mês atual</button><button type="button" class="btn sm" data-per="ant">Mês anterior</button><button type="button" class="btn sm" data-per="30">Últimos 30 dias</button></div></div>
      <button class="btn pri" type="submit">Gerar relatório</button>
    </form><div id="r-err"></div></section>
    <div id="r-out" aria-live="polite"></div>`;

  const gerar = async () => {
    const de = $('#r-de').value, ate = $('#r-ate').value, loc = $('#r-local').value, proc = $('#r-proc').value, orig = $('#r-orig').value;
    $('#r-err').innerHTML = '';
    if(!de || !ate || de > ate){ $('#r-err').innerHTML = alerta('err', 'Período inválido: a data inicial deve ser igual ou anterior à final.'); $('#r-de').focus(); return; }
    $('#r-out').innerHTML = carregando('Gerando relatório…');
    const filtros = qb => { if(proc) qb = qb.eq('procedimento_id', proc); if(orig) qb = qb.eq('unidade_origem_id', orig); return qb; };
    const [reg, prod, fila, vagas] = await Promise.all([
      fetchAll(() => filtros(sb.from('vw_solicitacoes').select('*').gte('created_at', de+'T00:00:00').lte('created_at', ate+'T23:59:59').order('id'))),
      fetchAll(() => { let qb = filtros(sb.from('vw_solicitacoes').select('*').gte('vaga_data', de).lte('vaga_data', ate).in('status', ['agendada','realizada','faltou']).order('id'));
        if(loc) qb = qb.eq('unidade_executante_id', loc); return qb; }),
      fetchAll(() => filtros(sb.from('vw_solicitacoes').select('*').in('status', ['pendente','autorizada']).order('id'))),
      fetchAll(() => { let qb = sb.from('vagas').select('id,unidade_executante_id,procedimento_id,status').gte('data', de).lte('data', ate).order('id');
        if(loc) qb = qb.eq('unidade_executante_id', loc); if(proc) qb = qb.eq('procedimento_id', proc); return qb; }),
    ]);
    const cnt = (l, st) => l.filter(r => r.status === st).length;
    const real = cnt(prod,'realizada'), falt = cnt(prod,'faltou'), aConf = prod.filter(r => r.status === 'agendada' && r.vaga_data < hoje).length;
    const tempos = reg.filter(r => r.data_agendamento).map(r => (new Date(r.data_agendamento) - new Date(r.created_at)) / 864e5);
    const tMedio = tempos.length ? (tempos.reduce((a,b) => a+b, 0) / tempos.length).toFixed(1).replace('.', ',') : '—';
    const espMed = fila.length ? Math.round(fila.reduce((a, r) => a + r.dias_espera, 0) / fila.length) : 0, espMax = fila.length ? Math.max(...fila.map(r => r.dias_espera)) : 0;
    const agrupa = (l, chave) => { const m = new Map(); l.forEach(r => { const k = chave(r); if(!m.has(k)) m.set(k, []); m.get(k).push(r); }); return m; };
    const ocT = cnt(vagas,'ocupada'), blT = cnt(vagas,'bloqueada');

    const gProd = [...agrupa(prod, r => r.unidade_executante_nome + '||' + r.procedimento_nome)].sort((a,b) => a[0].localeCompare(b[0]));
    const linProd = gProd.map(([k, l]) => { const [u, p] = k.split('||'); const r = cnt(l,'realizada'), f = cnt(l,'faltou');
      return [u, p, l.length, r, f, cnt(l,'agendada'), pct(f, r+f)]; });
    const gFila = [...agrupa(fila, r => r.procedimento_nome)].sort((a,b) => b[1].length - a[1].length);
    const linFila = gFila.map(([p, l]) => [p, l.length, l.filter(emRegulacao).length, Math.round(l.reduce((a,r) => a + r.dias_espera, 0) / l.length), Math.max(...l.map(r => r.dias_espera)),
      ...Object.keys(PRIORIDADES).map(k => l.filter(r => r.prioridade === k).length)]);
    const gOrig = [...agrupa(reg, r => r.unidade_origem_nome || r.unidade_solicitante_nome)].sort((a,b) => b[1].length - a[1].length);
    const linOrig = gOrig.map(([o, l]) => [o, l.length, l.filter(r => r.numero_guia).length, cnt(l,'realizada'), cnt(l,'faltou'), l.filter(r => ['pendente','autorizada','devolvida'].includes(r.status)).length, cnt(l,'negada'), cnt(l,'cancelada')]);
    const gVag = [...agrupa(vagas, v => nomeUnidade(v.unidade_executante_id) + '||' + nomeProc(v.procedimento_id))].sort((a,b) => a[0].localeCompare(b[0]));
    const linVag = gVag.map(([k, l]) => { const [u, p] = k.split('||'); const oc = cnt(l,'ocupada'), bl = cnt(l,'bloqueada');
      return [u, p, l.length, oc, cnt(l,'livre'), bl, pct(oc, l.length - bl)]; });
    const linNom = [...prod].sort((a,b) => (a.vaga_data + a.vaga_hora).localeCompare(b.vaga_data + b.vaga_hora))
      .map(r => [fmtData(r.vaga_data), fmtHora(r.vaga_hora), r.numero_guia, r.paciente_nome, cpfOculto(r.paciente_cpf), r.procedimento_nome, r.unidade_executante_nome, STATUS[r.status]]);

    const filtrosTxt = [loc ? 'Local: ' + nomeUnidade(+loc) : 'Todos os locais', proc ? 'Procedimento: ' + nomeProc(+proc) : 'Todos os procedimentos', orig ? 'Origem: ' + nomeUnidade(+orig) : 'Todas as origens'].join(' · ');
    $('#r-out').innerHTML = `
      <div class="print-only" style="margin-bottom:8px"><img src="assets/regula-posse-emblema.png" alt="Regula Posse" style="height:36px"><h2 style="margin:4px 0">${h(ORGAO)} — Relatório de Regulação</h2></div>
      <div class="periodo"><span>Período: <b>${fmtData(de)} a ${fmtData(ate)}</b></span><span>${h(filtrosTxt)}</span><span>Emitido em ${fmtDataHora(new Date())} por ${h(S.perfil.nome)}</span></div>
      <div class="kpis">
        ${kpi({ l:'Solicitações registradas', v:reg.length, s:'criadas no período' })}
        ${kpi({ l:'Atendimentos agendados', v:prod.length, s:'com data de atendimento no período', c:'azul' })}
        ${kpi({ l:'Realizados', v:real, s:'execução confirmada pelo local', c:'verde' })}
        ${kpi({ l:'Faltas', v:falt, s:`absenteísmo ${pct(falt, real+falt)} = faltas ÷ (realizados + faltas)`, c:'vermelho' })}
        ${kpi({ l:'Sem confirmação', v:aConf, s:'datas já passadas sem registro de realização ou falta', c:'amarelo' })}
        ${kpi({ l:'Fila atual', v:fila.length, s:`hoje · espera média ${espMed} dia(s), máxima ${espMax} dia(s)`, c:'roxo' })}
        ${kpi({ l:'Tempo médio até agendar', v:tMedio === '—' ? '—' : tMedio + ' dias', s:'do registro ao agendamento, para as registradas no período', c:'teal' })}
        ${kpi({ l:'Ocupação das vagas', v:pct(ocT, vagas.length - blT), s:`${num(ocT)} ocupadas de ${num(vagas.length - blT)} (sem bloqueadas)`, c:'teal' })}
      </div>
      ${tabelaRel('producao', 'Produção por local e procedimento', ['Local','Procedimento','Agendados','Realizados','Faltas','A confirmar','% Falta'], linProd,
          linProd.length ? ['TOTAL', '', prod.length, real, falt, cnt(prod,'agendada'), pct(falt, real+falt)] : null, [2,3,4,5,6],
          'Atendimentos com data de vaga no período. "A confirmar" = ainda sem registro de realização ou falta. % Falta = faltas ÷ (realizados + faltas).')}
      ${tabelaRel('ocupacao', 'Ocupação das agendas', ['Local','Procedimento','Vagas','Ocupadas','Livres','Bloqueadas','% Ocupação'], linVag,
          linVag.length ? ['TOTAL','', vagas.length, ocT, cnt(vagas,'livre'), blT, pct(ocT, vagas.length - blT)] : null, [2,3,4,5,6],
          'Vagas com data no período. % Ocupação = ocupadas ÷ (vagas − bloqueadas).')}
      ${tabelaRel('fila', 'Fila de espera atual (demanda reprimida)', ['Procedimento','Aguardando','Em regulação','Espera média (dias)','Maior espera (dias)', ...Object.values(PRIORIDADES).map(p => p.l)], linFila,
          linFila.length ? ['TOTAL', fila.length, fila.filter(emRegulacao).length, espMed, espMax, ...Object.keys(PRIORIDADES).map(k => fila.filter(r => r.prioridade === k).length)] : null, [1,2,3,4,5,6,7,8],
          'Retrato de hoje (não depende do período): solicitações aguardando regulação ou vaga. Espera = dias desde o registro.')}
      ${tabelaRel('origem', 'Solicitações por unidade de origem', ['Origem do pedido','Registradas','Agendadas','Realizadas','Faltas','Em aberto','Negadas','Canceladas'], linOrig, null, [1,2,3,4,5,6,7],
          'Solicitações registradas no período, agrupadas por quem emitiu o pedido médico, com a situação atual de cada uma.')}
      ${tabelaRel('nominal', 'Lista nominal de atendimentos', ['Data','Hora','Guia','Paciente','CPF','Procedimento','Local','Situação'], linNom, null, [],
          'Atendimentos com data no período. O CPF aparece parcialmente oculto para proteger o paciente.')}`;
    $$('[data-csv]', el).forEach(b => b.onclick = () => { const r = REL[b.dataset.csv]; baixarCSV(`${b.dataset.csv}_${de}_${ate}`, r.cab, r.linhas); });
  };
  $('#r-f').onsubmit = e => { e.preventDefault(); gerar(); };
  $$('[data-per]', el).forEach(b => b.onclick = () => {
    const p = b.dataset.per;
    if(p === 'mes'){ $('#r-de').value = ini; $('#r-ate').value = hoje; }
    if(p === 'ant'){ const a = addMes(hoje.slice(0,7), -1); $('#r-de').value = a + '-01'; $('#r-ate').value = isoDe(a, diasNoMes(a)); }
    if(p === '30'){ $('#r-de').value = addDias(hoje, -29); $('#r-ate').value = hoje; }
    gerar();
  });
  await gerar();
}


/* ---------------- início ---------------- */
boot().catch(e => {
  registrarErro(e, 'boot');
  document.body.insertAdjacentHTML('afterbegin', `<div class="alert err" role="alert" style="margin:16px"><span class="ai">⚠</span><div><b class="t">Não foi possível iniciar o sistema</b>${String(e.message).replace(/</g,'&lt;')}</div></div>`);
});
