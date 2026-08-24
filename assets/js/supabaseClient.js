// ⚠️ CONFIGURAÇÃO NECESSÁRIA
// Crie um projeto gratuito em https://supabase.com, depois vá em
// Project Settings > API e copie os dois valores abaixo.
//
// A "anon key" é uma chave PÚBLICA (feita para ficar no navegador do
// usuário) — a segurança de verdade vem das políticas de Row Level
// Security (RLS) configuradas no banco, não do sigilo dessa chave.
// Por isso ela pode ficar aqui no código sem problema.

const SUPABASE_URL = "https://ngnpqjocaptjeahseyqv.supabase.co";
const SUPABASE_ANON_KEY = "sb_publishable_AdjBGcxo_J2q-TBs-5bC7A_EUYQa4d8";

const supabaseClient = window.supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY);
