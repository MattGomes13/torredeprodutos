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
├── admin-usuarios.html      → (admin) lista usuários e cria novos administradores
├── assets/
│   ├── css/style.css         → estilo visual compartilhado por todo o portal
│   └── js/
│       ├── supabaseClient.js → configuração da conexão com o Supabase
│       └── auth.js           → login, logout, sessão e checagem de perfil
├── modules/
│   └── torre-de-produtos/    → 1º sistema integrado
│       ├── home.html         → escolha entre "Hub" e "Produtos"
│       ├── hub.html          → visão macro consolidada (importa roadmaps exportados)
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
  role text default 'stakeholder' check (role in ('admin', 'po', 'stakeholder')),
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

-- função de apoio, usada pelas policies abaixo para checar "é admin?"
create or replace function is_admin()
returns boolean language sql stable as $$
  select exists(select 1 from profiles where id = auth.uid() and role = 'admin');
$$;

-- admin pode editar o perfil de qualquer usuário (definir role, nome etc.)
create policy "admin atualiza qualquer perfil"
on profiles for update
using ( is_admin() )
with check ( is_admin() );

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

-- lista usuários (id + e-mail interno + perfil) — só admin consegue chamar.
-- usada em admin-usuarios.html e no "gerenciar acesso" da Torre de Produtos.
drop function if exists list_users();
create or replace function list_users()
returns table(id uuid, email text, role text) language plpgsql security definer as $$
begin
  if not is_admin() then
    raise exception 'apenas administradores podem listar usuários';
  end if;
  return query
    select au.id, au.email::text, coalesce(p.role, 'stakeholder')
    from auth.users au
    left join profiles p on p.id = au.id
    order by au.email;
end;
$$;
grant execute on function list_users() to authenticated;
```

### 5.2 Hub de Produtos (visão consolidada)

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

create policy "Usuários logados podem ler o hub"
on hubs for select
using ( auth.role() = 'authenticated' );

create policy "Usuários logados podem gravar o hub"
on hubs for insert
with check ( auth.role() = 'authenticated' );

create policy "Usuários logados podem atualizar o hub"
on hubs for update
using ( auth.role() = 'authenticated' );

create policy "Usuários logados podem apagar o hub"
on hubs for delete
using ( auth.role() = 'authenticated' );
```

### 5.3 Produtos, acessos e épicos

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

-- (a função list_users() já foi criada lá no script 5.1 — reaproveitada aqui
-- pra escolher PO/stakeholders por e-mail na tela "Gerenciar acesso")

-- substitui de uma vez todos os épicos de um produto (usado ao salvar/importar
-- o roadmap) — evita fazer isso em 2 chamadas separadas (delete + insert) do
-- lado do navegador, o que deixaria uma janela de inconsistência.
create or replace function replace_epics(p_product_id uuid, p_items jsonb)
returns void language plpgsql as $$
begin
  if not (is_admin() or exists(select 1 from products p where p.id=p_product_id and p.po_user_id=auth.uid())) then
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
  is_admin()
  or po_user_id = auth.uid()
  or is_product_stakeholder(id)
);

create policy "admin cria produtos"
on products for insert
with check ( is_admin() );

create policy "admin ou po atualizam produto"
on products for update
using ( is_admin() or po_user_id = auth.uid() );

create policy "admin exclui produtos"
on products for delete
using ( is_admin() );

create policy "ver atribuições de stakeholder"
on product_stakeholders for select
using (
  is_admin()
  or user_id = auth.uid()
  or is_product_po(product_id)
);

create policy "admin gerencia atribuições de stakeholder"
on product_stakeholders for all
using ( is_admin() )
with check ( is_admin() );

create policy "ver épicos de produtos permitidos"
on epics for select
using ( exists (select 1 from products p where p.id = epics.product_id) );

create policy "admin ou po do produto gerenciam épicos"
on epics for all
using ( is_admin() or is_product_po(product_id) )
with check ( is_admin() or is_product_po(product_id) );
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

7. Depois disso, como admin, use:
   - **Administração** (card que aparece no dashboard só pra quem já é admin) → criar outros administradores (usuário + senha direto, mesma lógica do bootstrap).
   - **Produtos** → criar produtos e decidir quem é o PO de cada um / quem pode visualizar como stakeholder.

   Usuários do tipo PO/Stakeholder, por enquanto, só podem ser criados
   rodando SQL direto no Supabase (criar o usuário em Authentication >
   Users, e ajustar `profiles.role` se quiser) — uma tela pra isso fica
   pra etapa de perfis e permissões.

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

- **`home.html`** → escolher entre "Hub de Produtos" e "Produtos".
- **`hub.html`** → importa `.html` de roadmaps já exportados (de qualquer produto) e monta uma visão consolidada (financeiro, status geral, tabela combinada). Persistido na tabela `hubs`, compartilhado entre todo mundo do portal.
- **`produtos.html`** → mostra os produtos que o usuário logado pode acessar:
  - **Admin**: vê todos os produtos, pode criar novos e definir quem é o PO e quais stakeholders têm acesso de cada um (botão "Gerenciar acesso").
  - **PO**: vê só o(s) produto(s) em que é o responsável, com acesso total de edição.
  - **Stakeholder**: vê só os produtos liberados pra ele, em modo **somente leitura**.
- **`roadmap.html?product=<id>`** → o roadmap completo de 1 produto (o mesmo roadmap "Torre de Produtos" que você já usava localmente: Gantt, visão estratégica/financeira, lista, filtros, exportar Excel/PPT, gestão de layers, white-label, etc.), agora lendo/gravando os épicos na tabela `epics` do Supabase em vez de `localStorage`. PO e admin podem editar; Stakeholder só visualiza (os botões de criar/editar/excluir/importar ficam ocultos, e o Supabase também bloqueia essas ações no banco por segurança, mesmo que alguém tente burlar a tela).
  - Botão **"⬆ Importar"**: sobe um `.html` de roadmap já exportado (como os que você já tinha rodando localmente) e carrega todos os épicos, tipos e layers dele para dentro do produto atual no Supabase — é assim que cada PO migra os dados que já tinha, sem precisar redigitar nada.

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

## Pendências / próximos passos combinados

Fica para uma etapa própria (como combinado): a definição fina de **perfis e permissões**. Por enquanto só o perfil **admin** tem telas prontas (bootstrap + criar outros admins); o esquema já suporta PO e Stakeholder (tabela `profiles.role`, `products.po_user_id`, `product_stakeholders`), mas ainda faltam:
- Uma tela para criar usuários PO/Stakeholder direto do portal (hoje precisa rodar SQL/usar o painel do Supabase pra criar a conta e depois pode usar "Gerenciar acesso" em Produtos pra vincular a um produto).
- Uma tela para o admin trocar o `role` de um usuário já existente (hoje só dá pra fazer isso rodando SQL direto no Supabase).
- Exigir que o usuário defina/troque a própria senha no primeiro acesso (por enquanto, quem cria a conta já define a senha diretamente).
- O Hub (`hub.html`) hoje aceita salvar/apagar de **qualquer usuário logado** (não só admin/PO) — revisar se isso deve virar restrito também.
