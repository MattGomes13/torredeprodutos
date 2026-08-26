# Portal de Sistemas

Portal único com login e controle de perfis de usuário, reunindo vários
sistemas em HTML que antes eram independentes. Autenticação via
[Supabase](https://supabase.com) (plano gratuito).

## Estrutura do projeto

```
portal-sistemas/
├── index.html               → tela de login (global, vale para todos os sistemas)
├── setup-admin.html         → bootstrap: cria o 1º administrador do portal (só funciona 1 vez)
├── dashboard.html           → lista os sistemas que o usuário pode acessar
├── admin-usuarios.html      → (admin/manager) lista usuários, cria/edita perfis, redefine senha
├── assets/
│   ├── css/style.css         → estilo visual compartilhado por todo o portal
│   └── js/
│       ├── supabaseClient.js → configuração da conexão com o Supabase
│       └── auth.js           → login, logout, sessão e checagem de perfil
├── supabase/functions/
│   └── admin-reset-password/ → Edge Function: redefine a senha de outro usuário (precisa da service_role key, por isso roda no servidor do Supabase, não no navegador)
├── modules/
│   └── torre-de-produtos/    → 1º sistema integrado
│       ├── home.html         → escolha entre "Hub" e "Produtos"
│       ├── hub.html          → visão macro consolidada, sincronizada ao vivo com Produtos
│       ├── produtos.html     → lista de produtos do usuário (ou gestão, se admin)
│       └── roadmap.html      → roadmap completo de 1 produto (Gantt, financeiro, etc.)
└── README.md
```

Cada novo sistema que for integrado vira uma nova pasta dentro de
`modules/`, e ganha um card em `dashboard.html`.

## Configuração necessária (fazer 1 vez)

1. Crie uma conta e um projeto gratuito em https://supabase.com
2. Em **Authentication > Providers > Email**, deixe o login por e-mail habilitado, e **desligue "Confirm email"**. Isso é importante: o portal usa **usuário** (não e-mail) pra login — por baixo dos panos isso vira um e-mail interno tipo `seu.usuario@portal.local`, que não existe de verdade e não recebe e-mail de confirmação nenhum. Com "Confirm email" ligado, nenhuma conta criada pelo portal conseguiria entrar.
3. Em **Project Settings > API**, copie a **Project URL** e a **anon public key**.
4. Cole os dois valores em [assets/js/supabaseClient.js](assets/js/supabaseClient.js).
5. Em **SQL Editor**, rode os scripts abaixo, **nesta ordem** (cada um depende do anterior).

### 5.1 Perfis de usuário

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

### 5.2 Hub de Produtos (visão consolidada)

> ℹ️ Esta tabela `hubs` era usada numa versão anterior do Hub, baseada em
> upload manual de arquivos. Hoje o Hub busca tudo ao vivo das tabelas
> `products`/`epics` (seção 5.3), e não usa mais essa tabela. Deixamos o
> script aqui só por compatibilidade com quem já rodou antes — **pode
> pular esse bloco** em uma instalação nova.

```sql
create table hubs (
  id text primary key,
  products jsonb not null default '{}'::jsonb,
  product_order jsonb not null default '[]'::jsonb,
  version int not null default 1,
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users
);

alter table hubs enable row level security;

-- Stakeholder não acessa o Hub (só a área de Produtos, e só pra visualizar).
-- Todo o resto (admin, manager, po e qualquer outro perfil futuro) pode.
create policy "Não-stakeholder pode ler o hub"
on hubs for select
using ( auth.role() = 'authenticated' and not is_stakeholder() );

create policy "Não-stakeholder pode gravar o hub"
on hubs for insert
with check ( auth.role() = 'authenticated' and not is_stakeholder() );

create policy "Não-stakeholder pode atualizar o hub"
on hubs for update
using ( auth.role() = 'authenticated' and not is_stakeholder() );

create policy "Não-stakeholder pode apagar o hub"
on hubs for delete
using ( auth.role() = 'authenticated' and not is_stakeholder() );
```

### 5.3 Produtos, acessos e épicos

```sql
create table products (
  id uuid primary key default gen_random_uuid(),
  slug text unique not null,
  name text not null,
  po_user_id uuid references auth.users,       -- o PO responsável por este produto
  config jsonb not null default '{}'::jsonb,    -- tipos/layers/tema/logo do roadmap
  bu text,                                      -- área de negócio, pro comparativo por BU no Hub
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

-- (a função list_users() já foi criada lá no script 5.1 — reaproveitada aqui
-- pra escolher PO/stakeholders por e-mail na tela "Gerenciar acesso")

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

6. Com os 3 scripts acima já rodados, abra `setup-admin.html` no navegador e crie o **primeiro administrador** por lá (usuário + senha direto na tela) — ela só funciona antes de existir qualquer admin no portal.

   > ⚠️ **Atenção de segurança**: `setup-admin.html` fica acessível pra
   > qualquer visitante (sem login) até o primeiro admin ser criado — é
   > assim que ela consegue existir sem precisar de credenciais especiais.
   > Faça esse passo **antes** de deixar o site publicamente acessível
   > (ex: antes de publicar no GitHub Pages), ou faça isso localmente
   > primeiro. Depois que o primeiro admin existe, a função
   > `claim_first_admin` se recusa a rodar de novo — a tela para de
   > funcionar sozinha.

7. Depois disso, como admin (ou manager, pra PO/Stakeholder), use:
   - **Administração** (card no dashboard, visível pra admin e manager) → criar novos usuários de qualquer perfil que você tenha permissão de criar (usuário + senha direto).
   - **Produtos** → criar produtos e decidir quem é o PO de cada um / quem pode visualizar como stakeholder.

## Rodando localmente

Como não tem build/servidor, basta abrir `index.html` no navegador.
Se o Supabase reclamar de CORS ao abrir como `file://`, sirva a pasta
com um servidor simples (Node ou Python, o que você tiver instalado):

```bash
npx serve .
```
```bash
python -m http.server 8000
```

## Como funciona o módulo "Torre de Produtos"

- **`home.html`** → escolher entre "Hub de Produtos" e "Produtos" (Stakeholder não vê o card do Hub).
- **`hub.html`** → busca os produtos e épicos **direto do Supabase** (as mesmas tabelas `products`/`epics` que `roadmap.html` usa) e monta uma visão consolidada (financeiro, comparativo por BU, tempo médio de desenvolvimento, status geral, tabela combinada). Não existe mais upload/importação manual — qualquer produto criado, ou roadmap atualizado, em Produtos aparece aqui automaticamente na próxima vez que a tela carrega (ou clicando em "🔄 Atualizar"). Quem acessa vê só os produtos que o RLS já libera pra ele (admin/manager: todos; PO: só o(s) dele). **Stakeholder não tem acesso** (nem tela). A tabela `hubs` (usada numa versão anterior, baseada em upload) ficou sem uso — pode ser removida do banco se quiser, não afeta nada.
  - Botão **"🎤 Apresentação"**: exporta o painel (Visão Estratégica) em **PowerPoint** (slides com KPIs, comparativo por BU e valor por produto) ou **PDF** (abre a impressão do navegador — escolher "Salvar como PDF" no destino).
  - **BU (área de negócio)**: campo opcional por produto, definido em Produtos → Gerenciar acesso. Produto sem BU entra no grupo "Sem BU definida" no comparativo.
- **`produtos.html`** → mostra os produtos que o usuário logado pode acessar:
  - **Admin e Manager**: veem todos os produtos, podem criar novos e definir quem é o PO e quais stakeholders têm acesso de cada um (botão "Gerenciar acesso"). A única diferença entre os dois é que **só Admin cria/edita contas de usuário**.
  - **PO**: vê só o(s) produto(s) em que é o responsável, com acesso total de edição.
  - **Stakeholder**: vê só os produtos liberados pra ele, em modo **somente leitura**.
- **`roadmap.html?product=<id>`** → o roadmap completo de 1 produto (o mesmo roadmap "Torre de Produtos" que você já usava localmente: Gantt, visão estratégica/financeira, lista, filtros, exportar Excel/PPT, gestão de layers, white-label, etc.), agora lendo/gravando os épicos na tabela `epics` do Supabase em vez de `localStorage`. Admin, Manager e PO podem editar; Stakeholder só visualiza (os botões de criar/editar/excluir/importar ficam ocultos, e o Supabase também bloqueia essas ações no banco por segurança, mesmo que alguém tente burlar a tela).
  - Botão **"⬆ Importar"**: sobe um `.html` de roadmap já exportado (como os que você já tinha rodando localmente) e carrega todos os épicos, tipos e layers dele para dentro do produto atual no Supabase — é assim que cada PO migra os dados que já tinha, sem precisar redigitar nada.
- **`admin-usuarios.html`** → Admin e Manager enxergam esta tela (Manager com opções mais restritas). Lista todos os usuários do portal, mostra o último login, permite editar perfil/ativar-desativar/redefinir senha de cada um, e cria novos usuários (Admin escolhe entre Admin/Manager/PO/Stakeholder; Manager só entre PO/Stakeholder), usuário e senha diretamente. Criar como PO exige associar a pelo menos 1 produto.

## Publicar no GitHub (e deixar online)

O projeto já é um repositório git local (`git log` mostra o histórico de
commits). Faltam só 2 coisas: mandar esse código pro GitHub, e (opcional)
ativar o GitHub Pages pra virar um link acessível.

### 1. Criar o repositório vazio no GitHub

1. Acesse https://github.com/new
2. Dê um nome (ex: `portal-sistemas`)
3. Deixe **sem** marcar "Add a README" / ".gitignore" / license — o repositório
   precisa nascer **vazio**, porque o projeto local já tem esses arquivos.
4. Escolha **Público** ou **Privado**:
   - Público → dá pra usar o GitHub Pages de graça (é o mais simples).
   - Privado → também dá pra usar Pages, mas só nos planos pagos do GitHub
     (Pro/Team). Repositório privado no plano free não publica Pages.
5. Clique em **Create repository**. Na próxima tela, copie a URL que aparece
   em "…or push an existing repository from the command line" (algo como
   `https://github.com/SEU-USUARIO/portal-sistemas.git`).

### 2. Conectar o projeto local e enviar

Rode isso dentro da pasta `portal-sistemas` (troque a URL pela sua):

```bash
git remote add origin https://github.com/SEU-USUARIO/portal-sistemas.git
git push -u origin master
```

Vai pedir login do GitHub na primeira vez (usuário + um **token de acesso
pessoal**, não a senha da conta — o GitHub explica como gerar um token se
pedir, ou abre uma janela de login se você tiver o Git Credential Manager
instalado, que é o padrão no Windows).

### 3. (Opcional) Ativar o GitHub Pages pra ter um link ao vivo

1. No repositório no GitHub, vá em **Settings > Pages**.
2. Em "Source", escolha a branch `master` e a pasta `/ (root)`.
3. Salve. Em alguns minutos o site fica em
   `https://SEU-USUARIO.github.io/portal-sistemas/`.

O projeto só usa caminhos relativos, então funciona normalmente nesse
endereço com subpasta (não precisa de domínio próprio nem configuração
extra).

> ⚠️ Antes de ativar o Pages (ou seja, antes do site ficar público),
> garanta que você já rodou o SQL do Supabase e já criou o primeiro admin
> pelo `setup-admin.html` **localmente** — veja o aviso de segurança sobre
> essa tela lá em cima. Depois de criado o primeiro admin, pode publicar
> sem problema.

## Perfis existentes hoje

| Perfil | Cria produtos / gerencia acesso | Edita roadmap | Acessa o Hub | Cria contas de usuário |
|---|---|---|---|---|
| **Admin** | ✅ todos os produtos | ✅ todos os produtos | ✅ | ✅ qualquer perfil |
| **Manager** | ✅ todos os produtos | ✅ todos os produtos | ✅ | ✅ só PO e Stakeholder |
| **PO** | ❌ | ✅ só o(s) produto(s) dele | ✅ | ❌ |
| **Stakeholder** | ❌ | ❌ (só visualiza) | ❌ | ❌ |

- **Admin** cria/edita/ativa/desativa contas de **qualquer** perfil.
- **Manager** cria/edita/ativa/desativa contas **só de PO e Stakeholder** — nunca consegue criar ou mexer numa conta Admin/Manager (checado no banco, não só escondido na tela).
- Um usuário PO pode estar associado a **mais de um produto**. Isso é feito de dois jeitos, que se equivalem (mexem no mesmo dado):
  - Em **Produtos → Gerenciar acesso** (por produto): escolhe qual usuário é o PO daquele produto.
  - Em **Administração de usuários** (por usuário): pra um usuário já com perfil PO, um botão "Produtos" abre a lista de todos os produtos com checkbox — marca/desmarca quais ele é responsável.
- Criar um usuário como **PO exige marcar pelo menos 1 produto** na hora da criação.

Não existe "excluir conta" de verdade — isso exigiria a `service_role` key do Supabase, que nunca deve aparecer no código do navegador (ela ignora toda regra de segurança do banco). **Desativar** tem o mesmo efeito na prática: a pessoa é deslogada na hora e não consegue mais entrar até ser reativada.

## Redefinir a senha de um usuário (Edge Function)

Botão **"Nova senha"** na tela de Administração — mesma regra de quem pode
usar: Admin em qualquer conta, Manager só em PO/Stakeholder. Ninguém troca
a própria senha por aqui.

Diferente do resto do projeto (que é só front-end + SQL), essa ação
**exige** rodar código no servidor do Supabase, porque trocar a senha de
**outra pessoa** só é possível com a Admin API do Supabase, que só
funciona com a `service_role` key — impossível de fazer com segurança
direto do navegador. A função já está pronta em
[`supabase/functions/admin-reset-password/index.ts`](supabase/functions/admin-reset-password/index.ts);
falta só publicá-la no seu projeto (uma vez só, não precisa repetir depois):

1. No painel do Supabase, vá em **Edge Functions** (menu lateral) → **Deploy a new function** (ou "Create a function").
2. Dê o nome exatamente **`admin-reset-password`** (o nome tem que bater com o que o portal chama).
3. Cole o conteúdo do arquivo `supabase/functions/admin-reset-password/index.ts` no editor que abrir.
4. Clique em **Deploy**.

Não precisa configurar nenhuma chave/segredo manualmente — o Supabase já
injeta a URL do projeto e a `service_role` key automaticamente dentro de
toda Edge Function, sem elas nunca saírem do lado do servidor.

## Pendências / próximos passos combinados

- Exigir que o usuário defina/troque a própria senha no primeiro acesso (por enquanto, quem cria a conta já define a senha diretamente).
