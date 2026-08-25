// Edge Function: admin-reset-password
//
// Redefine a senha de OUTRO usuário. Só existe como Edge Function porque
// isso exige a Admin API do Supabase (auth.admin.updateUserById), que só
// funciona com a service_role key — uma chave que NUNCA pode aparecer no
// código do navegador (ela ignora toda regra de segurança do banco).
//
// A service_role key não precisa ser configurada manualmente aqui: o
// Supabase já injeta ela (e a URL do projeto) como variável de ambiente
// em toda Edge Function automaticamente.
//
// Regra de permissão (mesma da tela de Administração):
// - Admin pode redefinir a senha de qualquer usuário.
// - Manager só pode redefinir a senha de usuários que hoje são PO ou
//   Stakeholder (nunca de um Admin/Manager).
// - Ninguém redefine a própria senha por aqui.
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

function jsonOk(body: unknown) {
  return new Response(JSON.stringify(body), { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } });
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  try {
    const { user_id, new_password } = await req.json();
    if (!user_id || !new_password || String(new_password).length < 6) {
      return jsonOk({ ok: false, error: 'Dados inválidos (senha precisa ter pelo menos 6 caracteres).' });
    }

    const authHeader = req.headers.get('Authorization');
    if (!authHeader) {
      return jsonOk({ ok: false, error: 'Não autenticado.' });
    }

    // Cliente com a sessão de quem chamou — só pra descobrir quem é e
    // checar o perfil dele, respeitando o RLS normal (não usa service_role).
    const supabaseUser = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_ANON_KEY')!,
      { global: { headers: { Authorization: authHeader } } }
    );
    const { data: { user: caller } } = await supabaseUser.auth.getUser();
    if (!caller) {
      return jsonOk({ ok: false, error: 'Sessão inválida.' });
    }
    if (caller.id === user_id) {
      return jsonOk({ ok: false, error: 'Você não pode redefinir a própria senha por aqui.' });
    }

    const { data: callerProfile } = await supabaseUser.from('profiles').select('role').eq('id', caller.id).single();
    const callerRole = callerProfile?.role || 'stakeholder';

    // Cliente com a service_role key — só usado DEPOIS de confirmar a permissão acima.
    const supabaseAdmin = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
    );

    const { data: targetProfile } = await supabaseAdmin.from('profiles').select('role').eq('id', user_id).single();
    const targetRole = targetProfile?.role || 'stakeholder';

    const podeComoAdmin = callerRole === 'admin';
    const podeComoManager = callerRole === 'manager' && ['po', 'stakeholder'].includes(targetRole);
    if (!podeComoAdmin && !podeComoManager) {
      return jsonOk({ ok: false, error: 'Sem permissão para redefinir a senha desse usuário.' });
    }

    const { error } = await supabaseAdmin.auth.admin.updateUserById(user_id, { password: new_password });
    if (error) {
      return jsonOk({ ok: false, error: error.message });
    }

    return jsonOk({ ok: true });
  } catch (e) {
    return jsonOk({ ok: false, error: String(e?.message || e) });
  }
});
