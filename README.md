# Regula Posse
Aplicação web de regulação municipal com login por e-mail e senha e Supabase Auth. Sirva a pasta em HTTPS. Configure em config.js a URL do projeto e sua chave pública publishable. Use apenas a chave de cliente. No banco dedicado vazio, aplique banco-de-dados/schema.sql uma vez; num banco que já está em produção, aplique só as migrações pendentes de `banco-de-dados/migracoes/`. Desabilite cadastro público no Supabase Auth e crie as contas individuais em Authentication > Users > Add user > Create new user.

## Liberação
Uma conta nova recebe perfil inativo. O operador autorizado do banco deve conferir o UUID do primeiro administrador em Authentication e executar no SQL Editor, substituindo o UUID:
```sql
update public.perfis set papel='admin', ativo=true where id='UUID-DA-CONTA'::uuid;
```
O administrador cadastra unidades e procedimentos e libera as demais contas em Usuários → Somente inativos → Editar. Selecione o papel, atribua a unidade e marque Acesso ativo.

A coluna **valor no banco** é o que fica em `perfis.papel` e o que as políticas de RLS usam. A tela mostra o nome da primeira coluna. Atenção ao atendente: na tela é **Atendente**, no banco é `solicitante`.

| Perfil (na tela) | Valor no banco | Atribuição |
|---|---|---|
| Administrador | `admin` | Gerencia usuários e unidades e tem acesso aos fluxos da central. |
| Regulador | `regulador` | Analisa os pedidos, autoriza, devolve e nega. Também opera a agenda central. |
| Agendador | `agendador` | Organiza filas e vagas, agenda e confirma atendimentos e gerencia cadastros operacionais. |
| Atendente | `solicitante` | Registra pacientes e pedidos, corrige devoluções e agenda pedidos da unidade conforme a regra do procedimento. |
| Executante | `executante` | Consulta as guias e confirma realização ou falta dos atendimentos da unidade vinculada. |

O pacote não inclui pacientes, unidades, procedimentos ou usuários fictícios. A URL e a chave pública do projeto ficam no config.js após criar o projeto Supabase. A senha individual é definida no Supabase Auth e nunca deve ser colocada no repositório.

## Catálogo SIGTAP

O banco contém 5.068 códigos e nomes da competência **11/2026**, extraídos de `TabelaUnificada_202611_v2611051737.zip` (espelho do FTP do DATASUS). A origem, o hash SHA-256 e a contagem constam em [data/sigtap-202611/manifesto.json](data/sigtap-202611/manifesto.json). O arquivo `tb_procedimento.txt` é de largura fixa: código nas posições 1–10 e nome nas posições 11–260, em Latin-1. O fluxo de extração está em `.github/workflows/preparar-sigtap.yml`, e os lotes SQL em `data/sigtap-202611/`.

Todos os procedimentos importados começam **inativos**. Em **Procedimentos**, selecione **Somente inativos**, busque por nome ou código, edite o tipo e a exigência de regulação, e ative somente os oferecidos pelo município. Cadastre os locais e associe os procedimentos habilitados a eles. Nenhum procedimento foi liberado automaticamente para agendamento.

Para atualizar uma competência futura, altere a URL e a competência no workflow, execute-o, revise o manifesto e aplique os novos lotes SQL. A importação preserva o campo `ativo`, o tipo, a especialidade e a regra de regulação dos códigos já existentes.

## Desenvolvimento

Não há build nem bundler: a pasta é servida como está. Só é preciso Node para rodar os testes.

```
index.html                    casca da página e a folha de estilo
js/app.js                     a aplicação
js/util.js                    funções puras: escape, datas, máscaras, validações
js/qr.js                      gerador de QR Code (modo byte, níveis L e M)
test/                         testes (node --test), sem dependência externa
ferramentas/                  verificadores do CI e scripts de manutenção
banco-de-dados/schema.sql     estado atual do banco, para instalação nova
banco-de-dados/migracoes/     o delta de cada versão, para banco em produção
banco-de-dados/testes/        testes do fluxo de regulação, em SQL
OPERACAO.md                   backup, restauração, endurecimento do acesso
```

Quem mantém o sistema no ar deve ler o **[OPERACAO.md](OPERACAO.md)** antes de a primeira unidade começar a usar — em especial o ensaio de restauração.

Antes de abrir um pull request:

```sh
node --test "test/**/*.test.js"        # funções puras e carga do módulo
node ferramentas/verificar-csp.mjs     # nada de script inline, origens conferem
node ferramentas/verificar-migracoes.mjs
```

O mesmo roda no CI (`.github/workflows/ci.yml`), que ainda aplica o schema e as migrações num Postgres limpo e confere que as restrições de CPF e CNS barram documento inválido.

### Regras que o projeto segue

**Escape de HTML.** O código monta HTML com template literal e `innerHTML`. Em código novo use o template `html` de `js/util.js`, que escapa por padrão, e marque com `raw()` só o HTML que o próprio sistema gerou:

```js
html`<td>${paciente.nome}</td>`          // escapado
html`<td>${raw(badgeSt(s))}</td>`        // HTML do sistema, preservado
```

O código antigo usa `${h(valor)}` em cada interpolação, o que está correto — a diferença é que ali o escape depende de alguém lembrar. Ao mexer numa função antiga, vale migrá-la.

**Nada de script inline.** O `index.html` declara um Content-Security-Policy que proíbe script inline, então não existe `onclick=` no HTML nem `<script>` com código dentro. Handler de clique vai em `ACOES_DOC`, em `js/app.js`, por delegação de evento — o que também sobrevive a qualquer redesenho de tela. `ferramentas/verificar-csp.mjs` reprova o PR que reintroduzir qualquer um dos dois.

Para fechar o `script-src` em `'self'` e deixar de depender do jsDelivr, rode `ferramentas/vendorizar-supabase.sh`: ele baixa o `supabase-js`, calcula o hash de integridade e imprime as duas linhas a trocar.

**Validação em dois lugares.** CPF e Cartão SUS são validados em `js/util.js`, para dar mensagem boa, e no banco, por constraint, porque validação só no navegador não vale nada — uma chamada direta à API REST com a chave publishable passaria por fora. Se mudar a regra num lado, mude no outro; os testes comparam as duas implementações.

**Datas.** Data de calendário trafega como `AAAA-MM-DD` e, ao virar `Date`, sempre com `T12:00`. À meia-noite uma virada de horário de verão joga a data para o dia anterior.

### Log de erro

Erro no navegador é gravado na tabela `erros` pela função `registrar_erro()`, visível só para administrador. Sem isso, "deu erro aqui" é irreproduzível: não há console aberto na recepção da unidade. Sequências de seis dígitos ou mais são mascaradas antes do envio, porque mensagem de erro do Postgres traz o valor que violou a restrição — que pode ser um CPF. O volume é limitado a 20 registros por usuário por hora, e `limpar_erros_antigos(dias)` apaga o que passou do prazo.

## Acompanhamento pelo paciente

Duas telas funcionam **sem login**, porque a Política Nacional de Regulação exige que o usuário acompanhe a própria situação e que a população veja as listas e os tempos de espera:

- `#/acompanhar` — pede o número do protocolo e a data de nascimento do paciente, e mostra situação, procedimento, tempo desde o pedido médico, posição na fila e, se já agendada, data, hora e local.
- `#/espera` — tempos médios por procedimento, agregados, sem nada pessoal.

A guia impressa traz um **QR Code** que abre a primeira tela com o protocolo já preenchido. O QR é gerado por `js/qr.js`, dentro do navegador: nenhum serviço externo recebe o protocolo do paciente, e o CSP não permitiria essa chamada de todo modo.

Os cuidados de privacidade dessa abertura, que é o primeiro caminho anônimo do banco:

- A função devolve situação, procedimento, posição e o agendamento. **Nunca** nome, CPF, CNS, telefone ou endereço — quem consulta já sabe de quem se trata.
- Exige protocolo **e** data de nascimento. O protocolo é sequencial e previsível, então sozinho não serve de segredo.
- A data de nascimento ainda é segredo fraco, então há trava de volume: 10 tentativas por protocolo por hora e 60 no banco todo por minuto. Toda tentativa fica registrada em `consultas_publicas`, visível só para administrador.
- Protocolo inexistente e data errada devolvem **exatamente a mesma resposta**. Distinguir os dois confirmaria a existência do protocolo.
- A função devolve o erro no campo `resultado` em vez de usar `raise exception`. Isso não é estilo: `raise` desfaz a transação inteira, inclusive o registro da tentativa, e a trava de volume ficaria sem efeito nenhum.

## As duas esperas

`dias_espera` conta da data em que a solicitação foi lançada no sistema, e é o que ordena a fila. `dias_desde_pedido` conta da data do pedido médico, que é a espera real do paciente. `dias_ate_insercao` é a diferença: quanto a unidade demorou para lançar o pedido.

A fila **não** foi reordenada para usar a data do pedido. Seria mais justo, mas mudaria retroativamente a posição de pacientes reais, e essa é decisão da regulação municipal, com data de corte definida — não de um deploy. O que o sistema faz é mostrar as duas medidas lado a lado, para o problema poder ser medido antes de ser decidido.

## Vulnerabilidade

A PNR-SUS manda a prioridade considerar risco, tempo de espera e vulnerabilidade, e atribui ao município definir os critérios. Então `criterios_vulnerabilidade` nasce **vazia**, como `CRITERIOS_RISCO` já nascia: sem critério cadastrado, o peso é zero e nada muda na fila. Quem cadastra é o administrador, em **Regulação → Critérios de vulnerabilidade**.

## Auditoria e privacidade

Três registros diferentes, que respondem perguntas diferentes:

| Onde | O que responde |
|---|---|
| `historico` | o que aconteceu com a solicitação, incluindo quem reclassificou o risco e de qual valor para qual |
| `historico_paciente` | quem alterou o cadastro de um paciente, qual campo, de que valor para qual |
| `acessos_paciente` | quem abriu o cadastro de um paciente, quando e em que tela |

Os três ficam em **Administração → Auditoria**, visíveis só para administrador.

Um limite do log de acesso que precisa ficar claro: o cliente lê a tabela `pacientes` direto pelo PostgREST, então ele **não** intercepta toda consulta ao banco. Registra abertura deliberada de cadastro pela aplicação — ficha, detalhe de solicitação e impressão de guia. Interceptar toda leitura exigiria tirar o acesso direto à tabela e passar tudo por função; está na lista de pendências.

## Envio ao Ministério (MIRA)

**Administração → Envio ao Ministério** monta os 16 elementos do Modelo de Informação da Regulação Assistencial e aponta o que impede o envio de cada registro — solicitação sem CID-10, procedimento sem código SIGTAP, unidade sem CNES, paciente sem CPF e sem CNS.

**A tela não transmite.** A transmissão usa o [Guia de Implementação FHIR da RNDS](https://fhir.saude.gov.br/rira/) e exige credenciamento do município. O que está pronto é a camada de dados; a serialização FHIR e o envio precisam ser validados contra o guia oficial antes de qualquer uso real.

Dois mapeamentos ficaram isolados em funções próprias, porque envolvem interpretação e a regulação municipal pode querer mudá-los: `mira_caracter()` reduz os quatro níveis de risco aos dois caracteres do modelo (eletivo e urgência), e `mira_status()` reduz os oito status às sete situações previstas.

Antes de usar, marque em **Locais e unidades** qual unidade opera a central: o CNES dela vai no elemento "estabelecimento regulador".

### Pendente

- Dividir `js/app.js` por tela (`js/telas/*.js`), hoje ainda num arquivo só.
- Mover a busca de pacientes e de procedimentos para consulta paginada no servidor: hoje os 5.068 procedimentos vão para a memória do navegador a cada login.
- Registrar acesso de leitura a cadastro de paciente, não só as mudanças de situação das solicitações.
- Escolher uma licença — sem arquivo `LICENSE`, outro município não pode reaproveitar o código com segurança jurídica.
- **Transmissão do MIRA para a RNDS.** A camada de dados está pronta; falta a serialização FHIR e o envio, que dependem do credenciamento do município.
- **Log de acesso abrangente.** Hoje registra abertura de cadastro pela aplicação. Cobrir toda leitura exige tirar o acesso direto do cliente à tabela `pacientes` e passar tudo por função.
- **Ambiente de homologação separado.** Hoje o preview do Netlify e o site publicado usam o mesmo banco, então testar no preview grava em produção.
