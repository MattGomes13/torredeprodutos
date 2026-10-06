# Guia de Reconstrução por Fases — Portal de Sistemas / Torre de Produtos

> **Para que serve este documento**: se você precisar migrar este sistema
> pra outro ambiente — outra hospedagem, outro banco, outra linguagem de
> backend, ou até pedir pra **outra IA** reconstruir do zero — este guia
> te dá o caminho completo, **fase a fase**, com **prompts prontos** pra
> cada etapa. Cada fase é um marco que já funciona sozinho: dá pra parar
> depois da Fase 1 (MVP) e já ter algo utilizável, subir a Fase 2 depois,
> e assim por diante.
>
> Este documento é **agnóstico de tecnologia** de propósito. Os prompts
> descrevem **o quê** construir (entidades, regras, telas, fluxos) — não
> "escreva esta função em JavaScript". Onde a implementação atual usa uma
> tecnologia específica (Supabase, PostgreSQL, HTML/JS puro), isso é
> citado como **"implementação de referência"**, não como obrigação. Se
> você (ou a IA que for reconstruir) escolher Node+Express+MySQL, ou
> Django+PostgreSQL, ou Firebase, ou qualquer outra coisa — o que importa
> é que as **regras de negócio e permissões** descritas sejam preservadas
> com a mesma força (ver seção 2).
>
> Documentos irmãos deste (não repita o conteúdo deles aqui, só consulte
> se precisar do detalhe exato da implementação atual):
> - `README.md` — setup passo a passo *desta* implementação (Supabase).
> - `PROJETO-VISAO-GERAL.md` — como *esta* implementação funciona hoje,
>   tela a tela, com o SQL exato usado.

---

## 0. Como usar este guia

1. Leia a **seção 1** (modelo de domínio) e a **seção 2** (regras que não
   podem ser perdidas) inteiras antes de começar — elas valem pra todas
   as fases.
2. Escolha sua stack (seção 3 dá as opções e o que cada marco técnico
   precisa suportar).
3. Execute as fases **em ordem** (seção 4). Cada fase tem:
   - 🎯 **Objetivo** — o que essa fase entrega, em 1 frase.
   - 📦 **Entidades** — o que existe no banco a partir desta fase.
   - 🗄️ **Prompt — Banco de dados**
   - ⚙️ **Prompt — Backend / regras de negócio**
   - 🖥️ **Prompt — Frontend** (pode ter mais de um, um por tela)
   - ✅ **Critério de "fase pronta"** — como testar que funcionou antes
     de ir pra próxima.
4. Cada prompt pode ser colado **direto numa IA de código** (Claude,
   GPT, Copilot, etc.) como instrução de trabalho — eles já vêm
   redigidos nessa intenção, na 2ª pessoa ("crie...", "implemente...").
5. Depois de terminar todas as fases que precisar, rode o checklist da
   **seção 5** pra confirmar paridade com o sistema original.

---

## 1. Modelo de domínio (entidades) — visão geral

Estas são as entidades do sistema, **independente de banco de dados**.
A implementação de referência usa Postgres com `jsonb` pra campos
flexíveis (ver nota no fim desta seção); se seu banco não tiver um tipo
JSON nativo, normalize esses campos em colunas ou numa tabela filha.

### 1.1 `User` (usuário / conta de login)
| Campo | Tipo | Obrigatório | Notas |
|---|---|---|---|
| id | uuid/identificador único | sim | gerado pelo sistema de auth |
| username | string, único | sim | login é por **usuário**, não e-mail (ver seção 2.3) |
| password | hash | sim | nunca em texto puro |
| created_at | timestamp | sim | |

### 1.2 `Profile` (perfil/permissão do usuário — 1:1 com `User`)
| Campo | Tipo | Obrigatório | Notas |
|---|---|---|---|
| user_id | FK → User | sim | chave primária = chave estrangeira |
| nome | string | não | nome de exibição |
| role | enum | sim | `admin` \| `manager` \| `po` \| `stakeholder` (default `stakeholder`) |
| ativo | boolean | sim | default `true`. `false` = acesso revogado sem apagar a conta |
| ultimo_login | timestamp | não | idealmente vem nativo do seu sistema de auth |

### 1.3 `Product` (produto/roadmap)
| Campo | Tipo | Obrigatório | Notas |
|---|---|---|---|
| id | uuid | sim | |
| slug | string, único | sim | usado em URLs |
| name | string | sim | |
| bu | string | não | Unidade de Negócio — texto livre (ver Fase 6) |
| config | JSON | sim, default `{}` | tipos/layers (cores, ícones), tema (cores do white-label), logo (data URL ou link) |
| created_at / updated_at | timestamp | sim | |

### 1.4 `ProductAccess` (associação usuário × produto — substitui "PO único")
| Campo | Tipo | Obrigatório | Notas |
|---|---|---|---|
| product_id | FK → Product | sim | PK composta com user_id |
| user_id | FK → User | sim | |
| pode_editar | boolean | sim, default `false` | `true` = edita o roadmap inteiro; `false` = só visualiza |

**Regra central**: não existe "o dono do produto". Um usuário pode
constar em várias linhas (vários produtos); um produto pode ter várias
linhas com `pode_editar=true` (vários editores ao mesmo tempo).

### 1.5 `Epic` (épico — o item de trabalho dentro de um roadmap)
| Campo | Tipo | Obrigatório | Notas |
|---|---|---|---|
| id | uuid | sim | chave interna |
| product_id | FK → Product | sim | |
| epic_id | string | não | o "código" visível do épico (ex: `BL_26.01`) — **não é único globalmente**, só um rótulo |
| titulo | string | sim | |
| desc | text | não | |
| tipo | string | sim | nome do "layer"/categoria (chave em `Product.config.tipos`) |
| status | enum | sim | ver lista completa na Fase 3 e nas Fases 7/8 (evolui em fases) |
| produto | string | não | nome do produto, redundante (cache de exibição) |
| modulo | string | não | |
| po | string | não | texto livre (nome do PO responsável, não é FK) |
| sprint | string | não | |
| esforco | number (horas) | não | |
| prioridade | enum | sim | `Alta` \| `Média` \| `Baixa` \| `Não Classificado` |
| prog | number 0-100 | sim | progresso — calculado (ver regra na Fase 3) |
| inicio, fim, entrega | date | não | |
| novaInicio, novaFim | date | não | "realocação" — nova data quando o épico é adiado/antecipado |
| quarter | enum | não | `Q1`\|`Q2`\|`Q3`\|`Q4`\|`Backlog` |
| late | boolean | calculado | atrasado (ver fórmula na Fase 3) |
| origem | string | não | origem da feature (ex: "Cliente", "Time") — **não confundir** com `origemDependencia` (Fase 9) |
| valor | number | não | valor financeiro (R$) |
| tipoValor | enum | não | `—` \| `Retenção` \| `Setup / Desenvolvimento` |
| previsibilidade | boolean | Fase 8 | |
| previsibilidadeDimensionado | boolean \| null | Fase 8 | null = checkbox nem marcado |
| previsibilidadeValor | number \| null | Fase 8 | |
| dependeDe | `{produtoId, produtoNome}` \| null | Fase 9 | |
| origemDependencia | `{produtoId, produtoNome, epicoOrigemId}` \| null | Fase 9 | só em clones (ver Fase 9) |
| divulgar | boolean | Fase 8 | flag simples, sem lógica |
| objetivo | texto livre (≤200) | Fase 8 | agrupa épicos na visão "Objetivos"; vazio = sem objetivo |
| faseBacklog | enum | Fase 7 | `geral`\|`estudo`\|`discovery`\|`comite`\|`delivery` — só relevante quando `status` é backlog/impedimento |
| observacoes | lista de `{data, texto}` | não | |
| atividades | lista de objetos | não | usado no cálculo automático de `prog` (Fase 3) |
| envolvidos | objeto | não | `{frontend, backend, qa, outraArea, outraQtd, sprints}` |

> **Nota sobre JSON vs. colunas**: a implementação de referência guarda
> quase tudo isso dentro de **uma coluna `item jsonb`** (com `product_id`
> e `epic_id` como colunas normais de fora, pra indexar/filtrar por elas
> no banco). Isso foi uma escolha deliberada: o épico tem MUITOS campos
> opcionais que foram crescendo ao longo do projeto, e um JSON evita uma
> migração de schema a cada campo novo. Se for reconstruir num banco/
> stack onde isso não é idiomático (MySQL sem JSON, ORMs muito rígidos),
> **normalize em colunas** — a lista acima já está pronta pra virar uma
> tabela `epics` com uma coluna por campo. As duas abordagens são
> igualmente válidas; só documentamos a decisão pra você escolher de
> olhos abertos.

### 1.6 Diagrama de relacionamento (texto)

```
User 1───1 Profile (role, ativo)
User 1───N ProductAccess N───1 Product (pode_editar por linha)
Product 1───N Epic
Epic N───1 Product (via dependeDe.produtoId / origemDependencia.produtoId,
                     referência lógica, não FK obrigatória — ver Fase 9)
```

---

## 2. Regras que NÃO podem se perder na reconstrução

Estas são as decisões de arquitetura/segurança que fazem o sistema
funcionar como pretendido. Reconstrua-as com a **mesma força**, seja
qual for a stack nova.

### 2.1 A autorização real vive no backend/banco, nunca só na tela
Em Postgres isso é RLS (Row Level Security): toda tabela sensível tem
políticas que barram a query no próprio banco, mesmo que alguém chame
a API direto (sem passar pela UI). **Se reconstruir noutra stack**,
implemente o equivalente: middleware de autorização no backend,
policies do Firebase, RBAC do banco, o que for — nunca confie só em
esconder botão na tela.

### 2.2 Hierarquia de perfis
`admin` > `manager` > `po` > `stakeholder`.
- **Manager tem os mesmos poderes de gestão que Admin** (produtos,
  roadmaps, Hub) — a ÚNICA diferença é que **só Admin cria, edita ou
  desativa contas Admin/Manager**. Manager pode criar/editar/desativar
  só contas PO e Stakeholder.
- **PO/Stakeholder não têm "poder" fixo por perfil** — o que eles podem
  editar depende da tabela `ProductAccess` (seção 1.4), não do `role`.
  `po` é o perfil típico de quem edita roadmaps, mas o que de fato
  autoriza é `pode_editar=true` numa linha específica.
- **Stakeholder nunca acessa o Hub consolidado** (só a área de um
  produto liberado, e só leitura).

### 2.3 Login por "usuário", não por e-mail
Login é feito digitando um **nome de usuário**, não um e-mail. Se seu
sistema de auth (Supabase Auth, Firebase Auth, etc.) só aceita e-mail,
faça a mesma tradução da implementação de referência: internamente,
`"fulano"` vira `"fulano@dominio-interno.local"` (um domínio que nunca
recebe e-mail de verdade). Se o usuário digitar algo que já tem `"@"`,
use como está (permite login por e-mail de verdade também, se algum
dia precisar).

### 2.4 Sem "excluir conta" de verdade — só desativar
Nunca implemente exclusão física de usuário pela UI comum (evita
precisar de uma chave/permissão de administrador do banco exposta em
qualquer lugar arriscado). `ativo=false` tem o mesmo efeito prático:
checar esse campo em toda tela protegida e deslogar/bloquear na hora.
**E, principalmente, no servidor:** a checagem de `ativo` tem que estar
dentro das funções/regras de permissão do banco (is_admin, is_manager,
is_editor_do_produto, is_membro_do_produto — todas exigem ativo=true) e na
função de servidor que troca senha. Só esconder na tela não adianta:
quem foi desativado ainda consegue logar e chamar a API direto.

### 2.5 Substituir a senha de OUTRA pessoa exige um passo privilegiado
Trocar a senha de outra pessoa (não a própria) é a única ação que
precisa de uma chave/permissão "root" do seu provedor de auth. **Essa
chave nunca pode chegar no navegador.** Isole essa ação numa função de
servidor (Edge Function, Lambda, endpoint de backend com a chave só
nas variáveis de ambiente do servidor) — nunca no código do cliente.

### 2.6 Não existe "o dono único" de um produto
Ver seção 1.4/2.1. Qualquer prompt de reconstrução que reintroduza um
campo tipo `products.owner_id` (um único responsável) está
regredindo — isso foi deliberadamente removido numa migração anterior
porque um produto real pode ter vários editores.

### 2.7 Idioma e nomenclatura
Todo o sistema é em **pt-BR** — nomes de campos internos, mensagens de
erro, rótulos de tela. Mantenha consistência (não misture inglês no
meio) se for gerar telas novas.

---

## 3. Marcos técnicos (visão panorâmica)

| Marco | Implementação de referência | O que precisa suportar (se trocar) |
|---|---|---|
| **Frontend** | HTML+CSS+JS puro, sem framework, sem build step | Qualquer framework (React, Vue, etc.) ou HTML puro de novo — o requisito real é: rodar como site estático (idealmente) e falar com o backend via API/SDK |
| **Backend** | Nenhum backend próprio — o navegador fala direto com o Supabase (Postgres+Auth) via SDK, usando uma chave pública, protegido por RLS | Pode ser "sem backend" (Firebase, Supabase, PocketBase) OU um backend tradicional (Node/Express, Django, Rails) — nesse caso, a autorização (seção 2.1) vira lógica no backend em vez de RLS |
| **Banco de dados** | PostgreSQL (via Supabase) | Qualquer SQL relacional (MySQL, SQLite) ou até NoSQL (Firestore) — se for NoSQL, adapte o modelo de relacionamento da seção 1.6 pra coleções/documentos |
| **Linguagem do banco** | SQL (dialeto PostgreSQL — `plpgsql` pras funções, `security definer` pra elevar privilégio pontualmente) | Se for outro SQL, troque a sintaxe de função (`plpgsql` → stored procedure do seu banco) mantendo a MESMA regra de autorização dentro dela |
| **Autenticação** | Supabase Auth (e-mail+senha, com tradução usuário→e-mail interno) | Qualquer provedor de auth com login por senha — o requisito é permitir login por "usuário" (seção 2.3) e ter um jeito de rodar uma ação privilegiada isolada (seção 2.5) |
| **Hospedagem** | GitHub Pages (site 100% estático, grátis) | Qualquer hospedagem estática, se manter o frontend sem build/servidor próprio; se adicionar um backend tradicional, precisa de hospedagem de servidor também |

---

## 4. Fases

Cada fase abaixo é **cumulativa** (a Fase N assume que 0..N-1 já
existem) e **entregável**: dá pra publicar o sistema real depois de
qualquer fase e ele já funciona (com menos funcionalidades que a
próxima fase vai adicionar).

---

### FASE 0 — Fundação técnica

🎯 **Objetivo**: ter projeto, banco e auth criados, prontos pra receber
código, sem nenhuma tela ainda.

📦 **Entidades**: nenhuma de domínio ainda — só a infraestrutura de auth
do seu provedor escolhido (geralmente já vem pronta, ex: `auth.users`
do Supabase).

🗄️ **Prompt — Banco de dados**
```
Crie um projeto novo no [SEU PROVEDOR DE BANCO/BACKEND ESCOLHIDO].
Habilite autenticação por e-mail e senha. Se o provedor exigir
confirmação de e-mail por padrão, DESLIGUE essa exigência — o login
deste sistema é por usuário, e o e-mail interno gerado
(usuario@dominio-interno.local) nunca recebe e-mail de confirmação de
verdade; com a confirmação ligada, ninguém conseguiria entrar.
```

⚙️ **Prompt — Backend / regras de negócio**
```
Não há regra de negócio nesta fase — só a configuração de infra acima.
```

🖥️ **Prompt — Frontend**
```
Crie a estrutura de pastas do projeto (sem build step — HTML/CSS/JS
puro, ou o equivalente na stack escolhida) com:
- Uma pasta de assets compartilhados (CSS global + JS de autenticação).
- Um arquivo de configuração de conexão com o backend/banco (URL +
  chave pública), isolado num único lugar fácil de trocar depois.
- Um arquivo de funções de autenticação reutilizáveis: traduzir
  usuário→e-mail interno, fazer login, fazer logout, pegar usuário
  logado, pegar perfil do usuário logado, e uma função "proteger
  página" que redireciona pro login se não houver sessão ativa —
  toda tela protegida do sistema vai chamar essa função no início.
```

✅ **Critério de pronto**: projeto criado, consegue conectar no banco a
partir de um arquivo de teste local, sem erro de CORS/configuração.

---

### FASE 1 — MVP: Autenticação e Perfis

🎯 **Objetivo**: sistema de login funcionando, com hierarquia de
perfis e uma tela de administração de usuários. **Isto já é publicável
como MVP** — mesmo sem nenhum produto/roadmap ainda, já dá pra logar,
criar outros usuários e controlar quem é admin/manager/po/stakeholder.

📦 **Entidades**: `User` (1.1), `Profile` (1.2).

🗄️ **Prompt — Banco de dados**
```
Crie a entidade Profile, associada 1:1 a User (o usuário nativo do seu
provedor de auth), com os campos: nome (texto), role (enum: admin,
manager, po, stakeholder — default stakeholder), ativo (booleano,
default true).

Garanta, com a força de autorização real do seu banco/backend (RLS,
middleware, o que for — ver seção 2.1 do guia):
- Qualquer usuário autenticado só pode LER o próprio perfil (a não ser
  que seja admin/manager, que precisam listar todos — ver função de
  listagem abaixo).
- Só admin pode fazer UPDATE direto na tabela de perfis.

Crie uma rotina automática que, toda vez que um novo usuário se
cadastra no sistema de auth, cria a linha correspondente em Profile
(com role padrão stakeholder).

Crie 4 funções de checagem de perfil, reutilizáveis em todas as regras
de autorização daqui pra frente:
- é_admin(): usuário logado tem role='admin'?
- é_manager(): usuário logado tem role='manager'?
- é_stakeholder(): usuário logado tem role='stakeholder'?
- pode_gerenciar(): é_admin() OU é_manager()? (uso constante em quase
  toda regra do sistema — Manager tem os mesmos poderes de gestão que
  Admin, exceto mexer em contas admin/manager)

Crie uma função "definir_perfil(usuario_id, novo_role, novo_nome)"
que:
- Levanta erro se o role pedido for inválido.
- Permite: admin definir QUALQUER role em QUALQUER usuário.
- Permite: manager definir só 'po' ou 'stakeholder', e só em usuários
  que hoje JÁ são 'po' ou 'stakeholder' (nunca promove ninguém a
  admin/manager, nunca mexe em quem já é admin/manager).
- Rejeita (com erro real, não silêncio) qualquer outra combinação.
Essa função precisa rodar com privilégio elevado o suficiente pra
fazer o UPDATE mesmo que a política normal de escrita não permitiria
— mas SEMPRE checando a regra acima primeiro, dentro da própria
função.

Crie uma função "definir_ativo(usuario_id, ativo)" com a mesma regra
de escopo (admin: qualquer um; manager: só po/stakeholder), que também
rejeita se o usuário tentar desativar a própria conta.

Crie uma função "contar_admins()" que qualquer visitante (mesmo sem
login) pode chamar, retornando quantos admins existem — vai ser usada
pela tela de bootstrap da Fase 1.1.

Crie uma função "tornar_primeiro_admin(nome)" que transforma o usuário
ATUAL em admin, mas só funciona se contar_admins() for zero — depois
que existir 1 admin, essa função se recusa a rodar de novo.

Crie uma função "listar_usuarios()" que retorna id, e-mail interno,
role, ativo e último login de TODOS os usuários — só chamável por
quem pode_gerenciar().
```

⚙️ **Prompt — Backend / regras de negócio**
```
Implemente a ação privilegiada de "redefinir senha de outra pessoa"
(seção 2.5 do guia) como uma rotina isolada de servidor (nunca no
cliente):
- Recebe: id do usuário alvo + nova senha.
- Descobre quem está chamando (via token de sessão) e checa a MESMA
  regra de escopo de definir_perfil (admin: qualquer um; manager: só
  po/stakeholder; ninguém troca a própria senha por aqui).
- Só então, com a credencial privilegiada do backend (nunca exposta ao
  cliente), troca a senha do usuário alvo.
```

🖥️ **Prompt — Frontend (tela 1/5): Login**
```
Crie uma tela de login com campos "Usuário" e "Senha". Ao enviar:
traduz o usuário pro e-mail interno, tenta autenticar, mostra erro
genérico se falhar ("Usuário ou senha inválidos"), e redireciona pro
dashboard se der certo. Se já existir uma sessão ativa ao abrir a
tela, pula direto pro dashboard sem pedir login de novo.
```

🖥️ **Prompt — Frontend (tela 2/5): Bootstrap do primeiro admin**
```
Crie uma tela de bootstrap que:
- Só funciona enquanto contar_admins() retornar zero (chame isso ao
  carregar a tela; se já houver admin, mostre uma mensagem e não deixe
  usar o formulário).
- Pede usuário + senha, cria a conta, e chama tornar_primeiro_admin.
- Avise no próprio texto da tela: isso fica acessível pra qualquer
  visitante sem login até o primeiro admin existir — use isso antes
  de publicar o site publicamente, ou faça localmente primeiro.
```

🖥️ **Prompt — Frontend (tela 3/5): Hub pós-login (dashboard)**
```
Crie uma tela que lista, em cards, os "sistemas"/módulos disponíveis
no portal (por enquanto só vai ter o card de Administração). Mostre o
card "Administração" só se o perfil do usuário logado for admin ou
manager.
```

🖥️ **Frontend (tela 4/5): Administração de usuários**
```
Crie uma tela (acessível só a admin/manager) que:
- Lista todos os usuários (via listar_usuarios()): e-mail, perfil,
  status ativo/inativo, último login.
- Por linha, permite: trocar o perfil (chamando definir_perfil — só
  mostre as opções de perfil que quem está logado tem permissão de
  atribuir), ativar/desativar (chamando definir_ativo), redefinir
  senha (chamando a rotina de servidor da Fase 1, com dupla
  confirmação de senha na tela).
- Um formulário de criar novo usuário: usuário + senha diretos (sem
  fluxo de "esqueci minha senha" nesta fase), escolhendo o perfil
  dentre os que quem está criando tem permissão de atribuir.
- Atenção a um detalhe técnico: se seu provedor de auth troca a sessão
  ativa do navegador pro usuário recém-criado ao criar uma conta
  (comportamento comum), guarde a sessão de quem está criando ANTES,
  e restaure ela logo depois — senão quem está criando o usuário
  "vira" o usuário novo sem querer.
```

🖥️ **Frontend (tela 5/5): proteção de página**
```
Em toda tela criada daqui pra frente (exceto login e bootstrap),
chame a função "proteger página" (Fase 0) no início do script — ela
redireciona pro login se não houver sessão, e também deve checar se o
perfil está com ativo=false (se estiver, força logout na hora).
```

✅ **Critério de pronto**: consegue criar o 1º admin, logar, criar um
segundo usuário (manager, po, stakeholder), trocar perfil, desativar e
reativar, redefinir senha de outra conta. Um manager NÃO consegue
promover ninguém a admin (teste isso explicitamente).

---

### FASE 2 — Produtos e Controle de Acesso

🎯 **Objetivo**: criar produtos e decidir quem tem acesso a cada um,
com o nível certo (editar ou só visualizar). Ainda sem roadmap de
verdade dentro do produto.

📦 **Entidades**: `Product` (1.3, sem o campo `bu` ainda — isso é Fase
6), `ProductAccess` (1.4).

🗄️ **Prompt — Banco de dados**
```
Crie a entidade Product: id, slug (único), name, config (campo
flexível tipo JSON, pode começar vazio — vai guardar tipos/layers/
tema/logo do roadmap a partir da Fase 3).

Crie a entidade ProductAccess: chave composta (product_id, user_id),
campo pode_editar (booleano, default false). Esta tabela é a ÚNICA
fonte de verdade de quem acessa o quê — não crie nenhum campo tipo
"dono" ou "responsável" em Product (ver seção 2.6 do guia).

Crie 2 funções de checagem, reutilizáveis daqui pra frente:
- é_editor_do_produto(produto_id): o usuário logado tem uma linha em
  ProductAccess pra esse produto com pode_editar=true?
- tem_acesso_ao_produto(produto_id): o usuário logado tem QUALQUER
  linha em ProductAccess pra esse produto (editar ou só visualizar)?

Regras de autorização (com a força real do seu banco/backend):
- Ver produtos: pode_gerenciar() [Fase 1] OU tem_acesso_ao_produto(id).
- Criar produto: só pode_gerenciar().
- Atualizar produto: pode_gerenciar() OU é_editor_do_produto(id).
- Excluir produto: só pode_gerenciar().
- Ver linhas de ProductAccess: pode_gerenciar() OU a própria linha (o
  usuário vendo o próprio acesso) OU é_editor_do_produto (um editor
  pode ver quem mais tem acesso ao mesmo produto).
- Escrever em ProductAccess (criar/editar/apagar linhas de acesso): só
  pode_gerenciar() — a tela de "Gerenciar acesso" é só pra admin/
  manager (PO/Stakeholder não conseguem mudar o próprio nível de
  acesso ou o de outros).
```

⚙️ **Prompt — Backend / regras de negócio**: nenhuma além das acima
(tudo já vive nas policies/funções do banco nesta fase).

🖥️ **Prompt — Frontend (tela 1/2): Lista de produtos**
```
Crie uma tela que lista os produtos que o usuário logado pode
acessar (a query já vem filtrada pela autorização do banco — não
filtre de novo no front). Se for admin/manager: mostra TODOS os
produtos, com botão "+ Novo produto" (pede só o nome, gera o slug
automaticamente) e um botão "Gerenciar acesso" por produto. Se for
PO/Stakeholder: mostra só os liberados, com uma tag indicando se o
usuário pode editar ou só visualizar aquele produto especificamente
(não confie no "role" da conta pra decidir isso — confie no
pode_editar daquela linha de ProductAccess).
```

🖥️ **Prompt — Frontend (tela 2/2): Gerenciar acesso**
```
Crie um modal/tela (só pra admin/manager) que, pra um produto
específico, lista TODOS os usuários do sistema e, pra cada um, um
seletor com 3 opções: "Sem acesso" / "Só visualizar" / "Editar e
visualizar" — pré-selecionado conforme o que já existe em
ProductAccess pra aquele usuário+produto (nenhuma linha = "Sem
acesso"). Ao salvar: apaga todas as linhas antigas de ProductAccess
daquele produto e recria só as que ficaram marcadas com algum nível.
```

✅ **Critério de pronto**: admin cria 2 produtos, dá "editar" pra um PO
num produto e "só visualizar" no outro; logando como esse PO, ele
consegue confirmar visualmente a diferença de nível entre os dois
produtos (mesmo sem ainda ter uma tela de roadmap de verdade — pode
testar só olhando a tag/nível mostrado na lista).

---

### FASE 3 — Roadmap Core (Épicos)

🎯 **Objetivo**: dentro de um produto, criar/editar/excluir épicos e
ver eles numa lista e numa grade por categoria/trimestre (a visão
"Roadmap" propriamente dita). Esta é a fase mais trabalhosa — é o
coração do sistema.

📦 **Entidades**: `Epic` (1.5) — só os campos SEM as marcações "Fase 7/
8/9" da tabela (ou seja: sem `dependeDe`, `origemDependencia`,
`previsibilidade*`, `divulgar`, `faseBacklog`; status ainda sem
Planejado/Alocado em Roadmap — só os status "clássicos": Finalizado,
Em andamento, Em backlog, Esforço levantado, Impedimento, Atrasado,
Pausado).

🗄️ **Prompt — Banco de dados**
```
Crie a entidade Epic dentro de Product, com os campos da seção 1.5
deste guia EXCETO: dependeDe, origemDependencia, previsibilidade,
previsibilidadeDimensionado, previsibilidadeValor, divulgar,
faseBacklog (esses vêm em fases posteriores). Status possíveis por
enquanto: Finalizado, Em andamento, Em backlog, Esforço levantado,
Impedimento, Atrasado, Pausado.

Se optar pela abordagem "um campo JSON com o épico inteiro" (ver nota
na seção 1.5), mantenha fora do JSON pelo menos: um id técnico
interno, o id do produto (product_id), e um "epic_id" (o código
visível) — esses 3 precisam ser colunas de verdade pra dar pra
filtrar/indexar rápido.

Crie uma função "substituir_epicos_do_produto(produto_id, lista_de_
epicos)" que APAGA todos os épicos daquele produto e insere a lista
inteira de novo, dentro de uma única transação — evite fazer isso
como "apagar tudo" + "inserir tudo" em 2 chamadas separadas do
cliente, porque deixa uma janela de inconsistência se uma das duas
falhar no meio. Essa função é a forma padrão de gravar o roadmap
inteiro de uma vez (usada toda vez que o usuário aperta "Salvar" na
tela de roadmap).
A função só executa se quem chamou for pode_gerenciar() OU
é_editor_do_produto(produto_id) daquele produto — senão, rejeita com
erro.

Regra de autorização pra leitura de Epic: qualquer um que tenha
QUALQUER acesso ao produto (tem_acesso_ao_produto) pode ler os épicos
dele. Pra escrita: só pode_gerenciar() ou é_editor_do_produto.
```

⚙️ **Prompt — Backend / regras de negócio**
```
Defina a fórmula de progresso efetivo de um épico (usada em toda
exibição de "%" e na barra de progresso):
- Se status = "Finalizado" → sempre 100%, independente de qualquer
  outro campo.
- Senão, se o épico tiver uma lista de "atividades" preenchida →
  calcula como (atividades concluídas) / (atividades não descartadas),
  arredondado.
- Senão → usa o valor manual que o usuário definiu no campo de
  progresso (slider/input direto).

Defina a regra de "atrasado" (late): um épico está atrasado se:
- status = "Atrasado" (explícito), OU
- tem data de fim no passado e o status não é "Finalizado" nem
  "Pausado" (comparar com a data de hoje).
```

🖥️ **Prompt — Frontend (tela 1/3): Modal de criar/editar épico**
```
Crie um formulário (modal ou página) com abas: Básico e Detalhe (as
abas Acompanhamento e JSON puro são opcionais nesta fase, podem vir
depois).

Aba Básico: ID (texto livre, só exibição/referência), Título*
(obrigatório), Descrição, Status (select com as 7 opções da Fase 3),
Quarter (Q1-Q4 ou Backlog), Tipo (select com os "layers"/categorias já
cadastrados no produto — ver Fase 3, item de configuração de layers,
mais abaixo), Produto (nome, geralmente fixo no produto atual),
Progresso (slider manual — mas mostre uma mensagem substituindo o
slider por texto fixo "100%" se o status for Finalizado).

Aba Detalhe: Prioridade, Módulo, PO (texto livre), Sprint, Esforço
(horas), Origem da Feature (texto livre), Data Inicial, Data Final,
Data de Entrega, um bloco de "Realocação de Datas" (Nova Data Inicial/
Final — se preenchido, mostra um selo "Realocado" no card do épico em
qualquer lista), um bloco de "Valor Monetário" (Valor em R$ + Tipo:
Retenção ou Setup/Desenvolvimento), e uma lista de Observações (texto
+ data, adicionadas uma a uma, sem editar as antigas — só adicionar
novas).

Botão Salvar: valida que Título não está vazio, monta o objeto do
épico, calcula prog (fórmula da Fase 3) e late (fórmula da Fase 3), e
grava (chamando substituir_epicos_do_produto com a lista inteira
atualizada). Botão Cancelar/Fechar: fecha sem salvar.

Adicione um botão de Excluir (com confirmação) em qualquer lugar onde
o épico aparece resumido (card/linha).
```

🖥️ **Prompt — Frontend (tela 2/3): Visão "Roadmap" (grade)**
```
Crie uma grade: uma linha por "tipo"/categoria (layer) cadastrado,
uma coluna por trimestre (Q1-Q4), célula = todos os épicos daquele
tipo+trimestre, renderizados como "cards pequenos" (pill) com: título,
status colorido, barra de progresso, ícones de alerta se atrasado/
com impedimento. Épicos sem quarter definido (quarter="Backlog")
aparecem numa linha extra abaixo de cada tipo, fora da grade principal.
Clicar num card abre o modal de editar (Fase 3, tela 1).

Cada "tipo"/layer precisa de uma cor e um ícone associados — crie uma
tela simples de gestão de layers (nome, cor, ícone, ordem de
exibição), guardada dentro de Product.config.
```

🖥️ **Prompt — Frontend (tela 3/3): Visão "Lista" e filtros**
```
Crie uma visão em lista simples (1 linha por épico, com os mesmos
dados resumidos do card) com busca por texto (título/id/produto) e
filtros por: período (quarter), status, prioridade, tipo, sprint.
Adicione um contador "X / Y épicos" refletindo o filtro atual.
```

✅ **Critério de pronto**: criar, editar, excluir épicos; ver eles na
grade e na lista; filtrar; confirmar que quem só tem "visualizar" não
consegue editar/excluir (nem pela tela, nem tentando chamar a função
de gravação direto).

---

### FASE 4 — Hub Consolidado (visão básica)

🎯 **Objetivo**: uma tela que junta todos os produtos visíveis pro
usuário numa visão só, com números consolidados.

📦 **Entidades**: nenhuma nova — só leitura agregada de `Product` +
`Epic` já existentes.

🗄️ **Prompt — Banco de dados**: nenhuma mudança de schema.

⚙️ **Prompt — Backend / regras de negócio**
```
Não crie um mecanismo de "upload" ou "importação manual" pro Hub — ele
deve buscar os dados AO VIVO das mesmas tabelas Product/Epic que a
tela de roadmap usa, toda vez que a tela carrega (e com um botão
"Atualizar" pra rebuscar sem recarregar a página inteira). Qualquer
produto criado ou roadmap atualizado aparece automaticamente aqui.
```

🖥️ **Prompt — Frontend**
```
Crie uma tela "Hub" (bloqueada pra quem for Stakeholder — nem mostre
o link) que:
- Busca todos os produtos visíveis pro usuário + todos os épicos
  deles.
- Mostra KPIs consolidados: total de épicos, finalizados (com %),
  em andamento (com %), atrasado/impedimento (com %), progresso médio,
  valor total mapeado.
- Mostra "valor mapeado por produto" (uma barra horizontal por
  produto, proporcional ao valor, com % de share do total).
- Mostra "distribuição de épicos": quantos por produto, e um gráfico
  de pizza por status geral.
- Mostra uma tabela combinada de todos os épicos de todos os
  produtos, com um seletor pra filtrar por produto e uma busca.
- Permite ocultar/reordenar produtos na tela (só na sessão local do
  navegador, não precisa persistir no banco).
```

✅ **Critério de pronto**: criar épicos em 2 produtos diferentes e
confirmar que o Hub mostra os números certos somados, e que um
Stakeholder não consegue acessar a tela.

---

### FASE 5 — Financeiro e Gráficos Mensais no Hub

🎯 **Objetivo**: enriquecer o Hub com visão temporal (por mês) e uma
aba de "itens que precisam de atenção agora".

📦 **Entidades**: nenhuma nova.

🖥️ **Prompt — Frontend (parte 1): Gráficos mensais**
```
No Hub, adicione dois gráficos de colunas empilhadas (uma coluna por
mês do ano corrente, um segmento colorido por produto):
- "Total de entregas por mês": conta épicos com status Finalizado,
  agrupados pelo mês da data de entrega (ou data de fim, se não tiver
  entrega).
- "Valor entregue por mês": mesma lógica, mas somando o campo "valor"
  em vez de contar 1 por épico.
Permita minimizar/recolher cada seção do Hub individualmente (estado
só na sessão, não precisa persistir).
```

🖥️ **Prompt — Frontend (parte 2): Aba Acompanhamento**
```
Crie uma segunda aba no Hub, "Acompanhamento", com 3 seções: épicos
atrasados (status=Atrasado), épicos com bloqueio (status=Impedimento),
e uma seção configurável de "cliente esperando" (busca por uma
palavra-chave num campo de texto, editável na própria tela — ex:
"setup de pagamento" — contra título/descrição dos épicos). Mostre a
contagem de cada seção e um card resumido por item encontrado.
```

✅ **Critério de pronto**: criar épicos finalizados com datas
diferentes em meses diferentes e ver o gráfico refletir certo; criar
um épico atrasado e ver aparecer em Acompanhamento.

---

### FASE 6 — Unidades de Negócio (BU)

🎯 **Objetivo**: agrupar produtos por "unidade de negócio" (BU) e
mostrar comparativos consolidados por BU, além de por produto (nunca
substituindo a visão por produto).

📦 **Entidades**: `Product.bu` (novo campo).

🗄️ **Prompt — Banco de dados**
```
Adicione um campo "bu" (texto, opcional) em Product.
```

🖥️ **Prompt — Frontend (parte 1): Definir a BU de um produto**
```
Na tela de "Gerenciar acesso" (Fase 2), adicione um campo de texto
"BU (unidade de negócio)" pro produto, com sugestão/autocomplete das
BUs já usadas em outros produtos (pra evitar grafias diferentes da
mesma BU, tipo "Finance" numa vez e "finance" noutra quebrando o
agrupamento). Mostre a BU como um selo pequeno no card do produto (na
lista de produtos e no Hub) e no cabeçalho da tela de roadmap.
```

🖥️ **Prompt — Frontend (parte 2): Consolidação por BU no Hub**
```
No Hub, adicione (SEM remover as versões por produto já existentes):
- "Valor mapeado por BU" (mesma barra horizontal da Fase 4, agora
  somando por BU — produto sem BU cai num grupo "Sem BU definida").
- "Comparativo por BU": 5 cards de destaque (BU com mais épicos, mais
  finalizados, mais em andamento, mais em atraso, maior faturamento) —
  mesmo formato do comparativo por produto, se você tiver feito um.
- "Total de entregas por mês (por BU)" e "Valor entregue por mês (por
  BU)": mesmos gráficos da Fase 5, agrupados por BU.
```

✅ **Critério de pronto**: 2 produtos com a mesma BU mostram os
números somados corretamente nas seções "por BU"; um produto sem BU
aparece em "Sem BU definida"; as seções por produto continuam
existindo e corretas.

---

### FASE 7 — Backlog Isolado + Kanban

🎯 **Objetivo**: separar épicos ainda não priorizados (Em backlog /
Impedimento) das visões normais, e dar um Kanban de triagem pra eles.

📦 **Entidades**: `Epic.faseBacklog` (novo campo).

🗄️ **Prompt — Banco de dados**
```
Adicione o campo "faseBacklog" (enum: geral, estudo, discovery,
comite, delivery — default "geral") em Epic. Só é relevante quando o
status do épico for "Em backlog" ou "Impedimento".
```

⚙️ **Prompt — Backend / regras de negócio**
```
Defina "é item de backlog" = status é "Em backlog" OU "Impedimento".

Toda consulta que alimenta as visões PRINCIPAIS (grade Roadmap, Gantt
se tiver, Lista, KPIs do topo, Estratégico/Hub) deve EXCLUIR itens de
backlog. Crie uma segunda função de consulta, só pro Kanban/Lista de
Backlog, que faz o oposto (só retorna itens de backlog).

Quando um épico entra em backlog pela primeira vez (ou reentra depois
de ter saído), faseBacklog reseta pra "geral". Se ele já estava em
backlog e só mudou de "Em backlog" pra "Impedimento" (ou vice-versa),
MANTÉM a faseBacklog onde estava (não reseta).
```

🖥️ **Prompt — Frontend (tela 1/2): Lista de Backlog**
```
Crie uma visão idêntica à "Lista" da Fase 3, mas usando a consulta que
só traz itens de backlog. Reaproveite os mesmos filtros e busca.
```

🖥️ **Prompt — Frontend (tela 2/2): Kanban de Backlog**
```
Crie uma visão Kanban com 5 colunas fixas, nesta ordem: "Backlog
geral", "Em Estudo e refinamento", "Em Discovery", "Aguardando
aprovação do comitê", "Enviado para Delivery". Cada card = um épico de
backlog, na coluna correspondente ao seu faseBacklog. Permita
arrastar um card entre colunas (atualiza faseBacklog); clicar no card
abre o modal de editar de sempre; um botão de excluir direto no card.

Regra especial da última coluna: mover um card pra "Enviado para
Delivery" muda automaticamente o status do épico pra "Em andamento" —
isso faz ele DEIXAR de ser um item de backlog, então ele desaparece do
Kanban/Lista de Backlog e passa a aparecer nas visões normais
(Roadmap, Lista, Gantt) como qualquer épico em andamento comum.

Aplique os mesmos filtros de busca/tipo/produto desta visão (é um erro
comum esquecer de ligar a busca no Kanban também — teste isso
explicitamente).
```

✅ **Critério de pronto**: criar um épico com status "Em backlog",
confirmar que ele NÃO aparece na grade Roadmap principal nem na Lista
normal; ele aparece na Lista de Backlog e no Kanban, na coluna
"Backlog geral"; arrastar até "Enviado para Delivery" e confirmar que
o status virou "Em andamento" e ele sumiu do Kanban e apareceu na
Lista normal.

---

### FASE 8 — Recursos Avançados do Épico

🎯 **Objetivo**: adicionar 4 recursos independentes entre si ao
formulário de épico — pode implementar em qualquer ordem dentro desta
fase.

📦 **Entidades**: `Epic.previsibilidade`, `previsibilidadeDimensionado`,
`previsibilidadeValor`, `Epic.divulgar` (novos campos). Também 2 novos
valores de `status`: `Planejado`, `Alocado em Roadmap`.

🗄️ **Prompt — Banco de dados**
```
Adicione a Epic: previsibilidade (booleano), previsibilidadeDimensionado
(booleano OU nulo), previsibilidadeValor (número OU nulo), divulgar
(booleano, default false).

Amplie a lista de status possíveis, incluindo: "Planejado" e "Alocado
em Roadmap" (além dos 7 já existentes da Fase 3).
```

🖥️ **Prompt — Frontend (recurso 1/4): Previsibilidade**
```
No formulário de épico (aba Detalhe), adicione um checkbox
"Previsibilidade". Quando marcado, revela 2 opções (radio): "Valor
previsto" (com um campo numérico R$ ao lado) OU "Ainda não foi
dimensionado" (sem campo nenhum — desabilita/limpa o campo de valor
se essa opção for escolhida). Guarde: previsibilidade=true/false
(checkbox), previsibilidadeDimensionado=true (tem valor) / false
(pendente) / null (checkbox nem marcado), previsibilidadeValor=número
ou null.
```

🖥️ **Prompt — Frontend (recurso 2/4): Novos status**
```
Adicione "Planejado" e "Alocado em Roadmap" nas opções de status do
formulário e em qualquer legenda de cores de status nas visões
principais. Escolha 2 cores novas, distintas das já usadas pelos
outros 9 status.
```

🖥️ **Prompt — Frontend (recurso 3/4): Divulgar**
```
Adicione um checkbox solto "Divulgar este épico quando for entregue"
— SEM nenhuma lógica associada, é só um lembrete visual. Mostre um
pequeno ícone/selo em qualquer lugar onde o épico aparece resumido
(card, linha de lista, card de kanban) quando divulgar=true.
```

🖥️ **Prompt — Frontend (recurso 4/4): Rascunho de épico novo + Clonar**
```
Rascunho: ao abrir o formulário pra CRIAR um épico novo (não editar um
já existente) e fechar sem salvar (botão cancelar, fechar, ou clicar
fora do modal), salve o preenchimento atual num rascunho local (no
armazenamento do navegador, escopado por produto — não precisa
sincronizar com o banco). Mostre um botão "Rascunho" no cabeçalho da
tela de roadmap sempre que existir um rascunho pendente pra aquele
produto; clicar reabre o formulário preenchido de onde parou. Salvar
com sucesso limpa o rascunho. Importante: editar um épico JÁ
EXISTENTE e cancelar NÃO deve mexer no rascunho de épico novo (são
independentes).

Clonar: no formulário de EDITAR um épico já existente, adicione um
botão "Clonar" que: salva as alterações atuais no épico original,
cria uma cópia idêntica com um novo id (mantendo tudo igual — título,
status, etc.), e abre o formulário de edição JÁ NA CÓPIA, pronta pra
ajustar o que for diferente (o caso de uso é épicos quase idênticos
entre bancos/clientes diferentes, mudando só um campo).
```

🖥️ **Prompt — Frontend (recurso extra): Objetivo + visão por Objetivo**
```
Na aba Detalhe do formulário do épico, adicione o campo "Objetivo":
texto LIVRE (até 200 caracteres), opcional, com sugestões (autocomplete)
dos objetivos já usados em outros épicos do produto — mas o usuário pode
digitar qualquer coisa. Ao salvar, normalize espaços (trim e espaços
repetidos viram um só). Guarde em Epic.objetivo. Inclua o campo no
rascunho de épico novo e na busca global. NÃO copie o objetivo para os
avisos de interdependência (clones) — eles são montados no servidor.

Crie uma nova visão no roadmap (botão ao lado das demais): "Objetivos".
Ela agrupa os épicos pelo texto do objetivo, ignorando diferença de
maiúscula/minúscula e espaços repetidos (o nome exibido é o da primeira
grafia encontrada), em ordem alfabética, e coloca no fim o grupo "Sem
objetivo definido" (fechado por padrão). Cada grupo é um bloco que abre e
fecha (o estado aberto/fechado sobrevive a redesenhos) e mostra no
cabeçalho: nome do objetivo, quantos finalizados de quantos, progresso
médio (barra + %), nº de épicos e valor SOMADO. Dentro do bloco, uma
linha por épico (ordenada pelo maior valor) com ID, título (+ produto),
status, barra de progresso com % e valor individual; clicar na linha
abre o épico pra edição. No topo, 4 cards: nº de objetivos, épicos com
objetivo, épicos sem objetivo e valor total. Entram TODOS os épicos
(inclusive os de backlog) menos os clones de interdependência; os
filtros e a busca do topo valem nessa visão, e ela se atualiza sozinha
depois de criar/editar/excluir um épico. Mostre também uma etiqueta
"🎯 objetivo" nas linhas da Lista.
```

✅ **Critério de pronto**: testar cada um dos 4 recursos isoladamente
(marcar previsibilidade com e sem valor; usar os 2 status novos;
marcar divulgar e ver o selo; fechar um épico novo sem salvar e
recuperar o rascunho; clonar um épico e confirmar que os 2 existem
separados).

---

### FASE 9 — Interdependência entre Produtos

🎯 **Objetivo**: permitir marcar que um épico depende de outro
produto, criando um aviso visível (clone) no roadmap desse outro
produto — mesmo que quem declarou a dependência não tenha permissão
de editar o produto alvo. **Esta é a fase mais delicada do ponto de
vista de segurança/permissão.**

📦 **Entidades**: `Epic.dependeDe`, `Epic.origemDependencia` (novos
campos).

🗄️ **Prompt — Banco de dados**
```
Adicione a Epic: dependeDe (objeto {produtoId, produtoNome} ou nulo) —
só no épico ORIGINAL. origemDependencia (objeto {produtoId,
produtoNome, epicoOrigemId} ou nulo) — só nos CLONES (avisos).

Crie uma função "criar_ou_atualizar_aviso_dependencia(produto_origem_
id, produto_alvo_id, epico_origem_id)" — repare: NÃO recebe o conteúdo
do clone. Ela mesma lê o épico de origem que já está gravado no banco e
monta o clone no servidor; senão qualquer usuário forjaria um épico
arbitrário no roadmap de outro produto. Ela:
- Só executa se quem chamou tiver permissão de EDITAR o produto de
  ORIGEM (é_editor_do_produto(produto_origem_id) ou pode_gerenciar())
  — repare que a checagem é sobre o produto de ORIGEM, não o alvo.
- Roda com privilégio elevado o suficiente pra criar um épico no
  produto ALVO mesmo que quem chamou não tenha acesso de edição lá —
  essa é a exceção deliberada: quem declara a dependência não precisa
  ser editor do outro produto, só do seu próprio.
- Monta o clone com uma LISTA DE CAMPOS PERMITIDOS (título, descrição,
  status, datas, quarter, progresso…) e deixa de fora tudo que é
  sensível ou interno do produto de origem: valor financeiro,
  observações, atividades, equipe, PO. Quem recebe o aviso pode nem ter
  acesso ao produto de origem.
- O campo "origemDependencia" (produto de origem, nome, épico) é
  preenchido pelo servidor com dados do banco — nunca aceito do cliente.
- Apaga qualquer aviso anterior pra esse mesmo épico de origem naquele
  produto alvo e insere o novo. IDENTIFIQUE o aviso pelo CONTEÚDO
  (origemDependencia.produtoId + epicoOrigemId dentro do próprio item),
  e dê ao clone um id único por origem (ex: "<épico>@<slug-do-produto-
  de-origem>"). Não use só "<épico>_dep": dois produtos com épicos de
  mesmo código se sobrescreveriam, e quando o produto alvo regrava o
  roadmap inteiro o id da linha pode ser reescrito a partir do JSON,
  deixando o aviso impossível de achar/remover.
- Fixe o "search_path" (ou equivalente) da função privilegiada.

Crie uma função irmã "remover_aviso_dependencia(produto_origem_id,
produto_alvo_id, epico_origem_id)" com a MESMA regra de permissão
(quem chama precisa editar o produto de origem), que só apaga o clone
correspondente no produto alvo.
```

⚙️ **Prompt — Backend / regras de negócio**
```
No formulário de editar épico: ao trocar o produto-alvo da
dependência (ex: de Produto A pra Produto B), chame primeiro a função
de REMOVER no alvo antigo, depois a função de CRIAR/ATUALIZAR no alvo
novo — nessa ordem, e só se o alvo realmente mudou (não dispare as 2
chamadas à toa se nada mudou). Ao desmarcar o checkbox de
interdependência (sem trocar de alvo, só removendo), chame só a
função de remover.

IMPORTANTE: salve o roadmap do produto de origem ANTES de chamar a
função de criar/atualizar (ela lê o épico gravado no banco). Se o código
do épico mudou na edição, remova o aviso pelo código ANTIGO e crie de
novo pelo novo. Verifique o erro de retorno das DUAS chamadas e mostre
aviso na tela se falharem. Ao excluir um épico que tinha dependência,
chame a função de remover também.
```

🔒 **Regra transversal — conteúdo vindo do banco é não confiável**
```
Títulos, descrições, nomes de produto e e-mails vêm do banco e podem ter
sido escritos por outro usuário (ou direto pela API, sem passar pela sua
tela). Nunca injete esse texto como HTML sem escapar. Além de escapar na
renderização, neutralize na LEITURA (ao carregar do banco, antes de
qualquer tela usar): troque "<" seguido de letra, aspas e "&" seguido de
"#"/entidade por caracteres visualmente parecidos e inofensivos —
recursivamente em strings, arrays e objetos (inclusive nas chaves). Como
isso roda no navegador de quem lê, não dá pra burlar gravando direto na
API. Cores/valores usados em atributos de estilo: aceite só formato
estrito (ex: hexadecimal), senão use um padrão.
```

🖥️ **Prompt — Frontend (parte 1): Declarar a dependência**
```
No formulário de épico (aba Detalhe), adicione um checkbox
"Interdependência com outro produto". Quando marcado, revela um
seletor com a lista de TODOS OS OUTROS produtos do sistema (não o
produto atual). Ao salvar com um produto selecionado, dispara a
criação/atualização do aviso (regra acima). O épico original passa a
mostrar um selo "Depende de: <produto escolhido>" em qualquer lugar
onde aparece resumido.
```

🖥️ **Prompt — Frontend (parte 2): Exibir e proteger o clone/aviso**
```
Em TODAS as visões onde um épico aparece (grade Roadmap, Lista, Lista
de Backlog, Kanban), quando o item for um clone (tem origemDependencia
preenchido): renderize numa cor de destaque diferente de todas as
outras (ex: laranja) e mostre o selo "Origem: <produto de origem>".

Ao abrir um clone pra "editar": mostre um banner explicativo no lugar
do checkbox de interdependência ("Este épico é um aviso automático
vindo de X — não pode ser editado aqui"), e desabilite TODOS os
campos do formulário (só deixe o botão de excluir ativo, fora do
modal, no card/linha normal — excluir o clone não afeta o épico
original). Esconda o botão de Salvar e o botão de Clonar quando for um
clone.
```

✅ **Critério de pronto**: no Produto A, marcar um épico como
dependente do Produto B (sendo o usuário editor só do Produto A, sem
acesso nenhum ao B) — confirmar que o clone aparece no roadmap do
Produto B em laranja, com a origem certa; editar o épico original e
trocar o produto-alvo pra C — confirmar que o aviso sumiu de B e
apareceu em C; abrir o clone em B/C e confirmar que está travado pra
edição, só com opção de excluir.

---

### FASE 10 — Exportação/Importação Offline + Polimento Visual

🎯 **Objetivo**: permitir levar um roadmap "pra fora" do sistema
(editar offline, devolver depois) e refinar a experiência visual.
Fase opcional/de polimento — não bloqueia nenhuma fase anterior.

🖥️ **Prompt — Frontend (parte 1): Exportar/Importar roadmap**
```
Na tela de roadmap, crie um botão "Exportar" que gera um arquivo
autocontido (HTML standalone, ou o formato equivalente na sua stack)
com todos os épicos e configurações do produto atual embutidos dentro
— de um jeito que, ao ser aberto sozinho (sem estar rodando dentro do
sistema, sem sessão nenhuma), ainda funcione: mostre os dados, permita
editar tudo localmente (épicos, cores, layers), mas ESCONDA qualquer
botão que dependa do backend (Salvar remoto, Importar, Limpar tudo) —
eles não fazem sentido sem o sistema do outro lado. Mantenha visível
o próprio botão de Exportar, pra quem editou offline devolver um novo
arquivo.

Crie o caminho inverso: um botão "Importar" que lê um desses arquivos
exportados e substitui os dados do produto atual pelos dados de
dentro do arquivo (via a mesma função de "substituir todos os
épicos" da Fase 3).
```

🖥️ **Prompt — Frontend (parte 2): Redesign do login**
```
(Opcional, só estético) Redesenhe a tela de login em layout
"split-screen": um painel decorativo de um lado (logo + frase de
efeito) e o formulário limpo do outro. Mantenha os mesmos campos e a
mesma lógica de autenticação — é só aparência.
```

✅ **Critério de pronto**: exportar um roadmap, abrir o arquivo sozinho
(fora do sistema, sem internet se possível), editar um épico, exportar
de novo, e reimportar dentro do sistema — os dados batem.

---

## 5. Checklist final de paridade de funcionalidades

Use esta lista pra conferir, depois de implementar todas as fases que
precisar, se nada ficou pra trás:

- [ ] Login por usuário (não e-mail), com tradução interna
- [ ] 4 perfis com a hierarquia certa (admin > manager > po > stakeholder)
- [ ] Manager nunca mexe em conta admin/manager
- [ ] Desativar usuário desloga na hora
- [ ] Redefinir senha de outro usuário isolado numa rotina privilegiada
- [ ] Produtos com acesso multi-usuário (sem "dono único")
- [ ] Nível de acesso por produto: editar vs. só visualizar
- [ ] CRUD de épicos com todos os campos da seção 1.5
- [ ] Cálculo de progresso (via atividades ou manual) e de atraso
- [ ] Visão Roadmap (grade), Lista, e — se implementado — Gantt
- [ ] Hub consolidado, com KPIs e Stakeholder bloqueado
- [ ] Gráficos mensais de entregas/valor no Hub
- [ ] Aba Acompanhamento (atrasados, impedimentos, palavra-chave)
- [ ] BU por produto + consolidação por BU no Hub (sem remover por produto)
- [ ] Isolamento de backlog (Em backlog/Impedimento fora das visões normais)
- [ ] Lista de Backlog + Kanban de 5 raias, com busca funcionando nos dois
- [ ] Mover pra "Enviado para Delivery" muda status automaticamente
- [ ] Previsibilidade (valor previsto ou pendente)
- [ ] Status Planejado e Alocado em Roadmap
- [ ] Flag Divulgar (só visual)
- [ ] Rascunho de épico novo ao fechar sem salvar
- [ ] Clonar épico existente
- [ ] Interdependência entre produtos (clone laranja, somente leitura,
      permissão elevada só no sentido origem→alvo)
- [ ] Exportar/Importar roadmap standalone (modo offline funcional)

---

## 6. Glossário rápido

| Termo | Significado |
|---|---|
| Épico | Item de trabalho dentro de um roadmap (feature, entrega) |
| Layer / Tipo | Categoria de agrupamento dos épicos (linha da grade) |
| BU | Unidade de Negócio — agrupamento de produtos pra comparativo |
| RLS | Row Level Security — autorização aplicada dentro do próprio banco |
| Clone / Aviso de dependência | Cópia somente-leitura de um épico, criada automaticamente noutro produto, sinalizando dependência cruzada |
| `pode_editar` | Campo que decide se uma associação usuário×produto dá direito de edição ou só leitura |
| Security definer | (Postgres) função que roda com privilégio elevado, ignorando a autorização normal — usada só onde é preciso deliberadamente (ex: interdependência entre produtos) |

---

*Este guia foi gerado a partir do estado real do sistema em produção
(repositório: https://github.com/MattGomes13/torredeprodutos). Sempre
que uma nova funcionalidade for adicionada ao sistema original, some
uma nova fase aqui, no mesmo padrão (Objetivo → Entidades → Prompts →
Critério de pronto), em vez de reescrever as fases já existentes.*
