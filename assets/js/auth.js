// Funções centrais de autenticação e perfil, usadas por todas as
// páginas do portal (login, dashboard e cada módulo/sistema).

// O portal usa "usuário" (não e-mail) como identificação de login — mas o
// Supabase Auth só sabe autenticar por e-mail. Pra reconciliar os dois sem
// precisar de um backend próprio, todo usuário criado pelo portal ganha um
// e-mail interno "usuario@portal.local" por baixo dos panos. Se alguém um
// dia digitar um e-mail de verdade (com "@"), usamos ele direto.
function usuarioParaEmail(usuario) {
  var u = (usuario || '').trim().toLowerCase();
  return u.indexOf('@') > -1 ? u : u + '@portal.local';
}

async function fazerLogin(usuario, senha) {
  return await supabaseClient.auth.signInWithPassword({ email: usuarioParaEmail(usuario), password: senha });
}

async function fazerLogout() {
  await supabaseClient.auth.signOut();
}

async function getUsuarioLogado() {
  const { data } = await supabaseClient.auth.getUser();
  return data.user || null;
}

// Busca a linha da tabela "profiles" do usuário logado (nome, role, etc).
async function getPerfil() {
  const user = await getUsuarioLogado();
  if (!user) return null;
  const { data } = await supabaseClient
    .from('profiles')
    .select('*')
    .eq('id', user.id)
    .single();
  return data;
}

// Chame no topo de qualquer página protegida. Se não houver sessão,
// redireciona para o login e retorna null.
async function protegerPagina(caminhoLogin) {
  const user = await getUsuarioLogado();
  if (!user) {
    window.location.href = caminhoLogin;
    return null;
  }
  return user;
}

// Preenche o avatar/nome do topbar e liga o botão de logout.
// loginPath = caminho relativo até o index.html a partir da página atual.
async function initTopbar(loginPath) {
  const user = await protegerPagina(loginPath);
  if (!user) return null;

  const perfil = await getPerfil();
  // Usuário desativado pelo admin: derruba a sessão na hora, em qualquer tela.
  if (perfil && perfil.ativo === false) {
    await fazerLogout();
    window.location.href = loginPath;
    return null;
  }
  const nome = (perfil && perfil.nome) ? perfil.nome : user.email;
  const iniciais = nome.trim().split(/\s+/).map(p => p[0]).slice(0, 2).join('').toUpperCase();

  const avatarEl = document.getElementById('topbarAvatar');
  const nameEl = document.getElementById('topbarName');
  if (avatarEl) avatarEl.textContent = iniciais;
  if (nameEl) nameEl.textContent = nome;

  window.__LOGIN_PATH__ = loginPath;
  return { user, perfil };
}

async function handleLogout() {
  await fazerLogout();
  window.location.href = window.__LOGIN_PATH__ || 'index.html';
}
