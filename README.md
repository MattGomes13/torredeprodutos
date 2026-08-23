# Portal de Sistemas

Portal único com login e controle de perfis de usuário, reunindo vários
sistemas em HTML que antes eram independentes. Autenticação via
[Supabase](https://supabase.com) (plano gratuito).

## Estrutura do projeto

```
portal-sistemas/
├── index.html              → tela de login (global, vale para todos os sistemas)
├── dashboard.html           → lista os sistemas que o usuário pode acessar
├── assets/
│   ├── css/style.css        → estilo visual compartilhado por todo o portal
│   └── js/
│       ├── supabaseClient.js → configuração da conexão com o Supabase
│       └── auth.js           → login, logout, sessão e checagem de perfil
├── modules/
│   └── torre-de-produtos/    → 1º sistema integrado
│       ├── home.html         → escolha entre "Hub" e "Produtos"
│       ├── role.html         → escolha de perfil (Stakeholder / PO)
│       ├── produtos.html     → lista de produtos (aguardando dados)
│       └── hub.html          → visão macro (aguardando dados)
└── README.md
```

Cada novo sistema que for integrado vira uma nova pasta dentro de
`modules/`, e ganha um card em `dashboard.html`.

## Configuração necessária (fazer 1 vez)

1. Crie uma conta e um projeto gratuito em https://supabase.com
2. Em **Authentication > Providers**, deixe o login por **Email** habilitado (já vem habilitado por padrão).
3. Em **Project Settings > API**, copie a **Project URL** e a **anon public key**.
4. Cole os dois valores em [assets/js/supabaseClient.js](assets/js/supabaseClient.js).
5. Em **SQL Editor**, rode o script abaixo para criar a tabela de perfis (guarda nome e o tipo de perfil de cada usuário):

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
```

6. Para criar os primeiros usuários: **Authentication > Users > Add user** (defina e-mail e senha manualmente).

## Rodando localmente

Como não tem build/servidor, basta abrir `index.html` no navegador.
Se o Supabase reclamar de CORS ao abrir como `file://`, sirva a pasta
com um servidor simples:

```bash
npx serve .
```

## Pendências (aguardando conteúdo)

- `modules/torre-de-produtos/produtos.html`: dados dos produtos.
- `modules/torre-de-produtos/hub.html`: dados do hub consolidado.
- Tela de detalhe do produto (roadmap por épico) ainda não foi migrada.
- Hoje a escolha de perfil (Stakeholder/PO) em `role.html` é livre —
  o ideal, quando o sistema estiver mais avançado, é essa escolha vir
  automaticamente do campo `role` da tabela `profiles` em vez de o
  usuário poder se autodeclarar PO.
