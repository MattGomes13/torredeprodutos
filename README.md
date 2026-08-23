# Portal de Sistemas

Portal único com login e controle de perfis de usuário, reunindo vários
sistemas em HTML que antes eram independentes. Autenticação via
[Supabase](https://supabase.com) (plano gratuito).

## Estrutura do projeto

```
portal-sistemas/
├── index.html               → tela de login (global, vale para todos os sistemas)
├── dashboard.html            → lista os sistemas que o usuário pode acessar
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
2. Em **Authentication > Providers**, deixe o login por **Email** habilitado (já vem habilitado por padrão).
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
```

> ⚠️ Depois de rodar isso, **defina você mesmo como admin**: crie seu usuário em
> Authentication > Users > Add user, depois rode
> `update profiles set role='admin' where id='COLE_AQUI_O_UUID_DO_SEU_USUARIO';`
> (o UUID aparece na lista de usuários do Supabase).

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

-- lista usuários cadastrados (id + e-mail) — só para o admin usar nas telas
-- de "gerenciar acesso" (escolher PO / stakeholders por nome de e-mail)
create or replace function list_users()
returns table(id uuid, email text) language plpgsql security definer as $$
begin
  if not is_admin() then
    raise exception 'apenas administradores podem listar usuários';
  end if;
  return query select au.id, au.email::text from auth.users au order by au.email;
end;
$$;
grant execute on function list_users() to authenticated;

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

alter table products enable row level security;
alter table product_stakeholders enable row level security;
alter table epics enable row level security;

create policy "ver produtos permitidos"
on products for select
using (
  is_admin()
  or po_user_id = auth.uid()
  or exists (select 1 from product_stakeholders ps where ps.product_id = products.id and ps.user_id = auth.uid())
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
  or exists (select 1 from products p where p.id = product_stakeholders.product_id and p.po_user_id = auth.uid())
);

create policy "admin gerencia atribuições de stakeholder"
on product_stakeholders for all
using ( is_admin() )
with check ( is_admin() );

create policy "ver épicos de produtos permitidos"
on epics for select
using (
  exists (
    select 1 from products p
    where p.id = epics.product_id
      and (is_admin() or p.po_user_id = auth.uid()
           or exists (select 1 from product_stakeholders ps where ps.product_id = p.id and ps.user_id = auth.uid()))
  )
);

create policy "admin ou po do produto gerenciam épicos"
on epics for all
using (
  exists (select 1 from products p where p.id = epics.product_id and (is_admin() or p.po_user_id = auth.uid()))
)
with check (
  exists (select 1 from products p where p.id = epics.product_id and (is_admin() or p.po_user_id = auth.uid()))
);
```

6. Para criar os primeiros usuários: **Authentication > Users > Add user** (defina e-mail e senha manualmente). Depois, como admin, use a tela **Produtos** do portal para criar produtos e decidir quem é PO de cada um / quem pode visualizar como stakeholder.

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

## Pendências / próximos passos combinados

- Fica para uma etapa própria (como combinado): a definição fina de **perfis e permissões** — por exemplo, uma tela para o admin trocar o `role` de um usuário (hoje só dá pra fazer isso rodando SQL direto no Supabase), e revisar se cada ação sensível do portal está checando o perfil certo.
- O Hub (`hub.html`) hoje aceita salvar/apagar de **qualquer usuário logado** (não só admin/PO) — mencionar se quiser restringir isso também na etapa de permissões.
