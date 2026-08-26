# Portal de Sistemas — Visão Geral e Guia de Reconstrução

> Este documento existe pra um cenário específico: se por qualquer motivo
> for preciso recriar este projeto do zero (outro ambiente, outra conta,
> **até com outra IA/ferramenta**), tudo que precisa ser sabido está aqui
> — não só o "como", mas o "porquê" das decisões, pra quem for reconstruir
> não repetir os mesmos erros que já foram corrigidos no caminho.

---

## 1. O que é este projeto

Um **portal único** com login e perfis de usuário, feito pra reunir vários
sistemas em HTML que antes rodavam soltos (cada um seu próprio arquivo,
sem login, sem controle de quem vê o quê). O primeiro sistema integrado é
a **Torre de Produtos**: roadmaps de produtos (épicos, Gantt, visão
financeira/estratégica) com uma visão consolidada de portfólio (o "Hub").

Repositório publicado: https://github.com/MattGomes13/torredeprodutos
Site publicado: https://mattgomes13.github.io/torredeprodutos/

## 2. Decisões de arquitetura (o "porquê")

- **100% estático, sem backend próprio.** Só HTML/CSS/JS puro, sem
  framework, sem build step, sem servidor. Hospedado de graça no
  **GitHub Pages**. A razão de ser assim: rapidez de entrega e zero custo
  de infraestrutura — qualquer alteração é só editar um arquivo e dar
  `git push`.
- **[Supabase](https://supabase.com) como backend-as-a-service**: banco
  Postgres (com Row Level Security) + autenticação, acessados **direto do
  navegador** via uma chave pública (a "anon"/"publishable key" — segura
  de expor, é feita pra isso).
- **RLS é a fronteira de segurança real, não a tela.** Toda ação sensível
  (quem pode ver/criar/editar o quê) é validada dentro do banco via
  políticas de Row Level Security. A interface escondendo um botão é só
  conveniência de UX — mesmo que alguém tente forçar a chamada pelo
  console do navegador, o banco recusa.
- **Login por "usuário", não por e-mail.** O Supabase Auth só autentica
  por e-mail. Pra dar a experiência de "usuário e senha" sem precisar de
  um backend próprio pra tradução usuário→e-mail, todo usuário criado no
  portal ganha um e-mail interno `usuario@portal.local` por baixo dos
  panos (função `usuarioParaEmail()` em `assets/js/auth.js`). Se alguém
  digitar um e-mail de verdade (contém "@"), ele é usado como está.
- **4 perfis com hierarquia clara**: `admin` > `manager` > `po` >
  `stakeholder`. A regra central que rege quase todas as políticas do
  banco: **Manager tem os mesmos poderes de gestão que Admin** (produtos,
  roadmaps, Hub, e pode até criar/editar contas — mas só de PO e
  Stakeholder), só que **nunca pode criar, promover ou mexer numa conta
  Admin/Manager**. Isso é checado nas próprias funções do banco
  (`set_user_role`, `set_user_ativo`), não só escondido na tela.
- **A única ação que precisa de um "servidor" de verdade**: redefinir a
  senha de **outra pessoa** exige a Admin API do Supabase, que só
  funciona com a `service_role` key — uma chave que nunca pode aparecer
  no navegador (ela ignora toda regra de RLS, é essencialmente root do
  banco). Pra isso existe uma única **Edge Function**
  (`supabase/functions/admin-reset-password`), que roda no servidor do
  Supabase, não no navegador.
- **Cada módulo antes solto virou uma pasta em `modules/`.** O roadmap
  "Torre de Produtos" (que já existia como um `.html` standalone, rodando
  localmente com dados salvos em `localStorage`) foi portado quase sem
  tocar na lógica de negócio (Gantt, dashboards financeiros, exportar
  Excel/PPT continuam iguais) — só a camada de persistência mudou, de
  `localStorage` pras tabelas do Supabase, e ganhou controle de acesso
  por perfil.
- **Sincronização automática, não upload manual.** A primeira versão do
  Hub de portfólio exigia subir manualmente um `.html` exportado de cada
  roadmap. Isso foi substituído: hoje o Hub busca os dados **ao vivo**
  das mesmas tabelas que o roadmap de cada produto usa — qualquer
  atualização em Produtos aparece no Hub automaticamente.

## 3. Estrutura de pastas

```
portal-sistemas/
├── index.html                → tela de login (global, vale para todos os sistemas)
├── setup-admin.html          → bootstrap: cria o 1º administrador do portal (só funciona 1 vez)
├── dashboard.html             → lista os sistemas que o usuário pode acessar
├── admin-usuarios.html       → (admin/manager) lista usuários, cria/edita perfis, redefine senha
├── assets/
│   ├── css/style.css         → estilo visual compartilhado por todo o portal
│   └── js/
│       ├── supabaseClient.js → configuração da conexão com o Supabase (URL + chave pública)
│       └── auth.js           → login, logout, sessão, checagem de perfil, tradução usuário→e-mail
├── supabase/functions/
│   └── admin-reset-password/ → Edge Function: redefine a senha de outro usuário
├── modules/
│   └── torre-de-produtos/    → 1º sistema integrado ao portal
│       ├── home.html         → escolha entre "Hub" e "Produtos"
│       ├── hub.html          → visão macro consolidada, sincronizada ao vivo com Produtos
│       ├── produtos.html     → lista de produtos do usuário (ou gestão, se admin/manager)
│       └── roadmap.html      → roadmap completo de 1 produto (Gantt, financeiro, Excel/PPT, etc.)
└── README.md                 → guia de setup passo a passo (Supabase, GitHub, etc.)
```

## 4. Perfis e permissões

| Perfil | Cria/gerencia produtos | Edita roadmap | Acessa o Hub | Cria contas de usuário |
|---|---|---|---|---|
| **Admin** | ✅ todos os produtos | ✅ todos os produtos | ✅ | ✅ qualquer perfil |
| **Manager** | ✅ todos os produtos | ✅ todos os produtos | ✅ | ✅ só PO e Stakeholder |
| **PO** | ❌ | ✅ só o(s) produto(s) dele | ✅ | ❌ |
| **Stakeholder** | ❌ | ❌ (só visualiza) | ❌ (sem acesso) | ❌ |

- Um usuário **PO pode estar associado a mais de um produto**. Isso é
  editado de dois jeitos equivalentes (mexem no mesmo campo
  `products.po_user_id`): em **Produtos → Gerenciar acesso** (por
  produto: escolhe o PO daquele produto) ou em **Administração de
  usuários** (por usuário: um botão "Produtos" abre um checklist de todos
  os produtos, marca/desmarca quais ele é responsável).
- Criar um usuário como **PO exige marcar pelo menos 1 produto** na hora
  da criação.
- **Não existe "excluir conta"** de verdade (exigiria a `service_role`
  key). **Desativar** tem o mesmo efeito prático: a pessoa é deslogada na
  hora (checado em `initTopbar()`, chamado no topo de toda página
  protegida) e não consegue mais entrar até ser reativada.
- Toda tabela sensível (`products`, `product_stakeholders`, `epics`,
  `profiles`) tem Row Level Security ligado, com políticas que refletem
  exatamente esta tabela.

## 5. O que cada tela faz

### `index.html` — login
Pede "Usuário" e "Senha". Internamente chama `fazerLogin()` (em
`auth.js`), que traduz o usuário pro e-mail interno e chama
`supabaseClient.auth.signInWithPassword`. Se já existe sessão ativa,
pula direto pro `dashboard.html`.

### `setup-admin.html` — bootstrap do 1º administrador
Só funciona **antes de existir qualquer admin** no portal (checa via RPC
`admin_count()`, chamável até por visitantes anônimos). Cria a conta via
`signUp()` e chama a RPC `claim_first_admin()`, que só aceita virar o
usuário atual em admin se a contagem de admins ainda for zero — depois
disso essa função se recusa a rodar de novo, travando a tela sozinha.
⚠️ Ponto de atenção de segurança: enquanto não existir o 1º admin, essa
tela é utilizável por qualquer visitante — faça esse passo **antes** de
publicar o site publicamente.

### `dashboard.html` — hub central pós-login
Lista os "sistemas" disponíveis como cards. Mostra o card **Torre de
Produtos** pra todo mundo, e o card **Administração** só pra quem é
`admin` ou `manager`.

### `admin-usuarios.html` — administração de usuários
Acesso: `admin` e `manager` (`manager` com menos opções). Lista todos os
usuários (via RPC `list_users()`), com perfil, status (ativo/inativo) e
**último login** (usa `auth.users.last_sign_in_at`, nativo do Supabase).
Por linha, permite: trocar o perfil (RPC `set_user_role`),
ativar/desativar (RPC `set_user_ativo`), redefinir senha (chama a Edge
Function `admin-reset-password`) e — só pra quem é PO — abrir um modal
"Produtos" pra editar a lista de produtos associados. Também tem o
formulário de criar novo usuário (usuário + senha diretos; se o perfil
escolhido for PO, exige marcar produtos). Toda a lógica de "quem pode
mexer em quem" é replicada no front (esconder controles) e no banco
(as RPCs recusam se não tiver permissão).

Detalhe técnico importante: criar um usuário chama `supabaseClient.auth.signUp()`,
que **troca a sessão ativa do navegador pro usuário recém-criado**. Por
isso o código sempre guarda a sessão de quem está criando (`getSession()`)
antes do `signUp()`, e restaura ela (`setSession()`) logo depois, pra
quem está criando continuar logado como si mesmo.

### `modules/torre-de-produtos/home.html`
Tela de escolha entre "Hub de Produtos" e "Produtos". Esconde o card do
Hub se o usuário for `stakeholder`.

### `modules/torre-de-produtos/produtos.html`
Mostra os produtos que o usuário pode acessar (a query já vem filtrada
pelo RLS — não precisa filtrar no front). Admin/Manager veem todos, têm
botão "+ Novo produto" e "Gerenciar acesso" (escolher PO + stakeholders
de cada produto, via modal com checklist) e "Excluir". PO/Stakeholder
veem só os produtos liberados pra eles, com uma tag indicando o papel.

### `modules/torre-de-produtos/roadmap.html?product=<id>`
O roadmap completo de **um** produto: KPIs, Gantt, visão
estratégica/financeira, lista de épicos, filtros, exportar Excel/PPT
(bibliotecas SheetJS e PptxGenJS embutidas no arquivo), gestão de
"layers"/tipos com cores, white-label (cores do tema), upload de logo.
Essa é a parte com mais código (a lógica de negócio do roadmap em si é
praticamente inalterada de um sistema que já existia rodando localmente
— só a persistência mudou de `localStorage` pro Supabase).

- **Nível de acesso** (`ACCESS_LEVEL`): `admin` (admin ou manager,
  edição total), `po` (é o `po_user_id` deste produto, edição total),
  `view` (qualquer outro caso, só leitura — botões de
  criar/editar/excluir/importar ficam ocultos via CSS `.view-only`, e o
  Supabase bloqueia essas ações no banco de qualquer forma).
- **Botão "⬆ Importar"**: sobe um `.html` de roadmap **já exportado** de
  outro lugar (mesmo padrão de arquivo) e carrega todos os épicos, tipos
  e layers pra dentro do produto atual no Supabase — usa uma extração por
  contagem de profundidade de colchetes (não regex ingênuo) pra achar
  `var DATA=[...]`, `var TYPES={...}`, etc. no arquivo, porque um roadmap
  já exportado contém, no próprio código-fonte da função de exportar, um
  trecho de texto que também parece com "var DATA=[" — um regex simples
  pode parar no lugar errado.
- Toda gravação de épicos passa pela RPC `replace_epics()` (substitui a
  lista inteira de uma vez, evitando inconsistência entre um delete e um
  insert separados).
- Config do roadmap (tipos/layers/tema/logo) fica em `products.config`
  (jsonb), não em colunas separadas.

### `modules/torre-de-produtos/hub.html`
Visão consolidada de portfólio. **Não tem upload nem "salvar"** — busca
`products` + `epics` do Supabase toda vez que a página carrega (função
`atualizarDados()`), e tem um botão "🔄 Atualizar" pra rebuscar sem
recarregar a página. O RLS já filtra sozinho quem vê o quê (mesmo
princípio de `produtos.html`). Permite ocultar/reordenar produtos na
tela (só nesta sessão, não persiste) e exportar um snapshot `.html` pra
compartilhar com alguém fora do portal. **Stakeholder é bloqueado** tanto
na tela (redirecionado) quanto no lado dos dados (RLS de `products`/`epics`
já não libera nada pra ele fora do que for stakeholder explícito).

### `supabase/functions/admin-reset-password/index.ts`
Única Edge Function do projeto. Recebe `user_id` + `new_password`, usa o
JWT de quem chamou (via header `Authorization`, que o `supabase-js`
manda sozinho) pra descobrir o perfil de quem está chamando com um
cliente comum (respeitando RLS), decide se pode (mesma regra do
`set_user_role`: admin em qualquer um, manager só em po/stakeholder), e
só então usa um cliente com a `service_role` key (injetada
automaticamente pelo Supabase como variável de ambiente, nunca
configurada manualmente) pra chamar
`auth.admin.updateUserById(user_id, { password })`.

## 6. Modelo de dados completo (SQL)

Este é o schema inteiro do banco, na ordem em que deve ser executado
(cada bloco depende do anterior). É o mesmo conteúdo do `README.md`
deste repositório — reproduzido aqui pra este documento ser
autossuficiente.

### 6.1 Perfis de usuário

```sql
create table profiles (
  id uuid references auth.users on delete cascade primary key,
  nome text,
  role text default 'stakeholder' check (role in ('admin', 'manager', 'po', 'stakeholder')),
  ativo boolean not null default true, -- desativar = revogar acesso sem apagar a conta
  created_at timestamp with time zone default now()
);

alter table profiles enable row level security;

create policy "Usuário vê o próprio perfil"
on profiles for select
using ( auth.uid() = id );

-- cria automaticamente uma linha em "profiles" sempre que alguém se cadastra
create function public.handle_new_user()
returns trigger as $$
begin
  insert into public.profiles (id, nome)
  values (new.id, new.raw_user_meta_data->>'nome');
  return new;
end;
$$ language plpgsql security definer;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute procedure public.handle_new_user();

-- funções de apoio, usadas pelas policies abaixo para checar o perfil
create or replace function is_admin()
returns boolean language sql stable as $$
  select exists(select 1 from profiles where id = auth.uid() and role = 'admin');
$$;

create or replace function is_manager()
returns boolean language sql stable as $$
  select exists(select 1 from profiles where id = auth.uid() and role = 'manager');
$$;

create or replace function is_stakeholder()
returns boolean language sql stable as $$
  select exists(select 1 from profiles where id = auth.uid() and role = 'stakeholder');
$$;

-- Manager tem os mesmos poderes de gestão de produtos que o admin — a
-- única coisa que só o admin pode fazer é criar/editar contas de usuário
-- (por isso "criar usuário" continua checando is_admin() sozinho, nunca
-- can_manage()).
create or replace function can_manage()
returns boolean language sql stable as $$
  select is_admin() or is_manager();
$$;

-- admin pode editar o perfil de qualquer usuário (definir role, nome etc.)
-- — de propósito só admin, não can_manage(): Manager não cria/edita contas.
create policy "admin atualiza qualquer perfil"
on profiles for update
using ( is_admin() )
with check ( is_admin() );

-- Define o perfil (role) de um usuário. Existe como função (em vez de um
-- UPDATE direto do navegador) por 2 motivos: a permissão é checada aqui
-- dentro, com erro de verdade se não puder (um UPDATE bloqueado por RLS
-- simplesmente não faz nada e não avisa erro), e porque a tela de criar
-- usuário troca de sessão internamente (signUp loga como o usuário novo);
-- fazer a definição do perfil como uma função evita depender de restaurar
-- a sessão do admin/manager no timing exato certo.
--
-- Regra: Admin pode definir qualquer perfil, em qualquer usuário. Manager
-- só pode definir 'po' ou 'stakeholder', e só em usuários que hoje já são
-- 'po' ou 'stakeholder' (ou acabaram de ser criados, com o padrão
-- 'stakeholder') — ou seja, Manager nunca consegue promover ninguém a
-- admin/manager, nem mexer em quem já é admin/manager.
create or replace function set_user_role(p_user_id uuid, p_role text, p_nome text default null)
returns void language plpgsql security definer as $$
declare
  v_role_atual text;
begin
  select role into v_role_atual from profiles where id = p_user_id;
  if p_role not in ('admin','manager','po','stakeholder') then
    raise exception 'perfil inválido: %', p_role;
  end if;
  if is_admin() then
    -- admin pode tudo
  elsif is_manager() and p_role in ('po','stakeholder') and coalesce(v_role_atual,'stakeholder') in ('po','stakeholder') then
    -- manager pode gerenciar po/stakeholder
  else
    raise exception 'sem permissão para definir esse perfil';
  end if;
  update profiles set role = p_role, nome = coalesce(p_nome, nome) where id = p_user_id;
end;
$$;
grant execute on function set_user_role(uuid, text, text) to authenticated;

-- Ativa/desativa o acesso de um usuário. Não existe "excluir conta" de
-- verdade sem a service_role key (que nunca deve ir pro código do
-- navegador) — desativar tem o mesmo efeito prático (a pessoa não consegue
-- mais entrar) sem esse risco. Mesma regra de escopo do set_user_role:
-- Manager só ativa/desativa quem já é po/stakeholder.
create or replace function set_user_ativo(p_user_id uuid, p_ativo boolean)
returns void language plpgsql security definer as $$
declare
  v_role_atual text;
begin
  if p_user_id = auth.uid() and p_ativo = false then
    raise exception 'você não pode desativar sua própria conta';
  end if;
  select role into v_role_atual from profiles where id = p_user_id;
  if is_admin() then
    -- admin pode tudo
  elsif is_manager() and coalesce(v_role_atual,'stakeholder') in ('po','stakeholder') then
    -- manager pode gerenciar po/stakeholder
  else
    raise exception 'sem permissão para ativar/desativar esse usuário';
  end if;
  update profiles set ativo = p_ativo where id = p_user_id;
end;
$$;
grant execute on function set_user_ativo(uuid, boolean) to authenticated;

-- quantos admins já existem — usado pela tela de bootstrap (setup-admin.html)
-- pra saber se ainda pode criar o primeiro. Roda mesmo sem ninguém logado.
create or replace function admin_count()
returns int language sql security definer as $$
  select count(*)::int from profiles where role = 'admin';
$$;
grant execute on function admin_count() to anon, authenticated;

-- deixa o USUÁRIO ATUAL virar o primeiro admin do portal — só funciona
-- se ainda não existir nenhum admin (senão, dá erro). É assim que a tela
-- setup-admin.html cria o admin inicial, sem precisar de service_role key.
create or replace function claim_first_admin(p_nome text)
returns void language plpgsql security definer as $$
begin
  if (select count(*) from profiles where role = 'admin') > 0 then
    raise exception 'já existe um administrador — peça pra ele criar seu acesso';
  end if;
  update profiles set role = 'admin', nome = coalesce(p_nome, nome) where id = auth.uid();
end;
$$;
grant execute on function claim_first_admin(text) to authenticated;

-- lista usuários (id + e-mail interno + perfil + último login) — admin ou
-- manager podem chamar (o Manager precisa disso pra escolher PO/stakeholder
-- em "Gerenciar acesso" e pra tela de administração). last_sign_in_at já
-- vem pronto do Supabase Auth, não precisamos rastrear login nós mesmos.
drop function if exists list_users();
create or replace function list_users()
returns table(id uuid, email text, role text, ativo boolean, ultimo_login timestamptz) language plpgsql security definer as $$
begin
  if not can_manage() then
    raise exception 'apenas administradores ou managers podem listar usuários';
  end if;
  return query
    select au.id, au.email::text, coalesce(p.role, 'stakeholder'), coalesce(p.ativo, true), au.last_sign_in_at
    from auth.users au
    left join profiles p on p.id = au.id
    order by au.email;
end;
$$;
grant execute on function list_users() to authenticated;
```

### 6.2 Produtos, acessos e épicos

```sql
create table products (
  id uuid primary key default gen_random_uuid(),
  slug text unique not null,
  name text not null,
  po_user_id uuid references auth.users,       -- o PO responsável por este produto
  config jsonb not null default '{}'::jsonb,    -- tipos/layers/tema/logo do roadmap
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table product_stakeholders (
  product_id uuid references products(id) on delete cascade,
  user_id uuid references auth.users on delete cascade,
  primary key (product_id, user_id)
);

create table epics (
  id uuid primary key default gen_random_uuid(),
  product_id uuid not null references products(id) on delete cascade,
  epic_id text,        -- o "id" original do épico dentro do roadmap, ex: BL_26.01
  item jsonb not null, -- o épico inteiro (título, status, datas, valor, observações...)
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- substitui de uma vez todos os épicos de um produto (usado ao salvar/importar
-- o roadmap) — evita fazer isso em 2 chamadas separadas (delete + insert) do
-- lado do navegador, o que deixaria uma janela de inconsistência.
create or replace function replace_epics(p_product_id uuid, p_items jsonb)
returns void language plpgsql as $$
begin
  if not (can_manage() or exists(select 1 from products p where p.id=p_product_id and p.po_user_id=auth.uid())) then
    raise exception 'sem permissão para editar este produto';
  end if;
  delete from epics where product_id = p_product_id;
  insert into epics (product_id, epic_id, item)
  select p_product_id, (elem->>'id'), elem
  from jsonb_array_elements(p_items) as elem;
end;
$$;
grant execute on function replace_epics(uuid, jsonb) to authenticated;

-- funções auxiliares "security definer": rodam ignorando RLS, e existem
-- só pra quebrar a referência circular entre as policies de products e
-- product_stakeholders (uma pergunta pra outra, que pergunta de volta —
-- sem essas funções, o Postgres entra em recursão infinita).
create or replace function is_product_po(p_product_id uuid)
returns boolean language sql stable security definer as $$
  select exists(select 1 from products where id = p_product_id and po_user_id = auth.uid());
$$;

create or replace function is_product_stakeholder(p_product_id uuid)
returns boolean language sql stable security definer as $$
  select exists(select 1 from product_stakeholders where product_id = p_product_id and user_id = auth.uid());
$$;

alter table products enable row level security;
alter table product_stakeholders enable row level security;
alter table epics enable row level security;

create policy "ver produtos permitidos"
on products for select
using (
  can_manage()
  or po_user_id = auth.uid()
  or is_product_stakeholder(id)
);

create policy "admin/manager cria produtos"
on products for insert
with check ( can_manage() );

create policy "admin/manager ou po atualizam produto"
on products for update
using ( can_manage() or po_user_id = auth.uid() );

create policy "admin/manager exclui produtos"
on products for delete
using ( can_manage() );

create policy "ver atribuições de stakeholder"
on product_stakeholders for select
using (
  can_manage()
  or user_id = auth.uid()
  or is_product_po(product_id)
);

create policy "admin/manager gerencia atribuições de stakeholder"
on product_stakeholders for all
using ( can_manage() )
with check ( can_manage() );

create policy "ver épicos de produtos permitidos"
on epics for select
using ( exists (select 1 from products p where p.id = epics.product_id) );

create policy "admin/manager ou po do produto gerenciam épicos"
on epics for all
using ( can_manage() or is_product_po(product_id) )
with check ( can_manage() or is_product_po(product_id) );
```

> A tabela `hubs` (de uma versão antiga, baseada em upload manual) **não
> é mais necessária** — não inclua ela numa reconstrução do zero.

### 6.3 Edge Function — redefinir senha de outro usuário

Arquivo completo em `supabase/functions/admin-reset-password/index.ts`
(ver seção 5 acima pro que ela faz). Precisa ser publicada manualmente
pelo painel do Supabase (Edge Functions → Deploy a new function → nome
exato `admin-reset-password` → colar o código → Deploy). Não precisa
configurar nenhuma chave — `SUPABASE_URL`, `SUPABASE_ANON_KEY` e
`SUPABASE_SERVICE_ROLE_KEY` já vêm injetadas automaticamente em toda
Edge Function pelo próprio Supabase.

---

## 7. Caminho 1 — Construir do zero

Ordem recomendada pra reconstruir tudo do absoluto zero, sem nenhum
arquivo do projeto original — só com este documento em mãos:

1. **Criar a estrutura de pastas** da seção 3.
2. **Montar o login e o layout compartilhado primeiro**: `index.html`
   (tela de login, campo "Usuário" + "Senha"), `assets/css/style.css`
   (visual: fundo navy `#1a3a5c`, cards brancos arredondados, ver
   qualquer arquivo `.html` do projeto pros tokens de cor exatos),
   `assets/js/supabaseClient.js` (placeholder de URL/chave) e
   `assets/js/auth.js` com as funções: `usuarioParaEmail`, `fazerLogin`,
   `fazerLogout`, `getUsuarioLogado`, `getPerfil`, `protegerPagina`,
   `initTopbar`, `handleLogout`. **Todo arquivo `.html` protegido chama
   `initTopbar(caminhoAteOLogin)` uma vez, no fim do script** — é o
   padrão usado em 100% das páginas do portal.
3. **Criar o projeto no Supabase** e rodar o SQL completo da seção 6
   (nessa ordem: 6.1 depois 6.2).
4. **Criar `setup-admin.html`** (bootstrap) e usar pra criar o 1º admin.
5. **Criar `dashboard.html`** com um card por sistema, mostrando o card
   "Administração" só se `role` for `admin` ou `manager`.
6. **Criar `admin-usuarios.html`** com a tabela de usuários + formulário
   de criação, seguindo exatamente as regras de permissão da seção 4/6.1.
7. **Publicar a Edge Function** `admin-reset-password` (seção 6.3) e
   ligar o botão "Nova senha" em `admin-usuarios.html`.
8. **Construir o módulo de produtos** (`modules/<nome-do-sistema>/`):
   - `home.html`: menu do módulo.
   - `produtos.html`: lista de produtos com RLS já filtrando por perfil,
     "Gerenciar acesso" (modal de PO + stakeholders por produto).
   - `roadmap.html?product=<id>`: a tela principal de edição de dados do
     produto (no nosso caso, um roadmap com Gantt/financeiro — pode ser
     qualquer outra coisa dependendo do sistema que está sendo
     integrado), lendo/gravando via uma tabela tipo `epics` + a RPC
     `replace_epics`. Sempre checar `ACCESS_LEVEL` (admin/po/view) antes
     de mostrar controles de edição.
   - `hub.html` (opcional): visão consolidada que busca ao vivo os dados
     de todos os produtos visíveis pro usuário — **não fazer** com
     upload manual, buscar direto das tabelas.
9. **Publicar no GitHub** (repositório vazio + `git remote add` +
   `git push`) e ativar GitHub Pages (repositório público, branch
   principal, pasta raiz) — ver README.md deste projeto pros comandos
   exatos.

## 8. Caminho 2 — Reconstruir a partir do zip existente

Se o código-fonte (a pasta `portal-sistemas` inteira, zipada) já está em
mãos, **não é preciso reescrever nada** — só reconectar as peças que
vivem fora do sistema de arquivos (o projeto Supabase é um serviço
externo, não vem dentro do zip):

1. **Descompactar o zip** normalmente.
2. **Criar um projeto novo no Supabase** (ou reutilizar um existente, se
   for o caso) — conta gratuita em https://supabase.com.
3. Em **Authentication → Providers → Email**, desligar **"Confirm
   email"** (essencial — sem isso login nenhum funciona, por causa do
   e-mail interno fake).
4. Rodar o **SQL completo da seção 6** deste documento no SQL Editor do
   novo projeto, na ordem (6.1 → 6.2).
5. Pegar a **Project URL** e a **Publishable key** (Project Settings →
   API) e colar em `assets/js/supabaseClient.js` (as duas constantes no
   topo do arquivo).
6. **Publicar a Edge Function** `admin-reset-password` (Edge Functions →
   Deploy a new function → nome exato → colar o conteúdo do arquivo →
   Deploy).
7. Abrir `setup-admin.html` localmente (duplo clique) e criar o 1º admin.
8. Se for subir pro GitHub: criar um repositório vazio, `git init` (se
   ainda não for um repositório git), `git remote add origin <url>`,
   `git push`, e ativar o GitHub Pages nas configurações do repositório.
9. Testar o login e navegar por todas as telas conferindo se cada
   perfil vê exatamente o que deveria (usar a tabela da seção 4 como
   checklist).

Nenhum arquivo de código precisa ser alterado além do passo 5 (as
credenciais do Supabase) — o resto do comportamento já está todo pronto
no próprio código.

## 9. Limitações conhecidas (no momento em que este documento foi escrito)

- Não existe fluxo de "usuário define/troca a própria senha" — hoje quem
  cria a conta já define a senha diretamente.
- Não existe "excluir conta" de verdade (só desativar) — decisão
  deliberada pra não precisar da `service_role` key no navegador.
- A tabela `hubs` (de uma versão anterior do Hub) ficou no banco sem uso
  — pode ser removida com segurança numa instalação nova.
