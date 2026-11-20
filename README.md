# Regula Posse
Aplicação web de regulação municipal com login por e-mail e senha e Supabase Auth. Sirva a pasta em HTTPS. Configure em config.js a URL do projeto e sua chave pública publishable. Use apenas a chave de cliente. No banco dedicado vazio, aplique banco-de-dados/schema.sql uma vez. Desabilite cadastro público no Supabase Auth e crie as contas individuais em Authentication > Users > Add user > Create new user.

## Liberação
Uma conta nova recebe perfil inativo. O operador autorizado do banco deve conferir o UUID do primeiro administrador em Authentication e executar no SQL Editor, substituindo o UUID:
```sql
update public.perfis set papel='admin', ativo=true where id='UUID-DA-CONTA'::uuid;
```
O administrador cadastra unidades e procedimentos e libera as demais contas em Usuários → Somente inativos → Editar. Selecione o papel, atribua a unidade e marque Acesso ativo.

| Perfil | Atribuição |
|---|---|
| Administrador | Gerencia usuários e unidades e tem acesso aos fluxos da central. |
| Regulador | Analisa os pedidos, autoriza, devolve e nega. Também opera a agenda central. |
| Agendador | Organiza filas e vagas, agenda e confirma atendimentos e gerencia cadastros operacionais. |
| Atendente | Registra pacientes e pedidos, corrige devoluções e agenda pedidos da unidade conforme a regra do procedimento. |
| Executante | Consulta as guias e confirma realização ou falta dos atendimentos da unidade vinculada. |

O pacote não inclui pacientes, unidades, procedimentos ou usuários fictícios. A URL e a chave pública do projeto ficam no config.js após criar o projeto Supabase. A senha individual é definida no Supabase Auth e nunca deve ser colocada no repositório.
