// =====================================================================
// Petit Bonbon — nettoyage des notes vocales
// Supprime du stockage « vocaux » les fichiers qui ne doivent plus exister :
//   - écoutés depuis plus de 5 minutes (écoute unique),
//   - signalés,
//   - jamais écoutés au bout de 24 heures,
//   - orphelins (envoi annulé, compte supprimé).
//
// L'app l'appelle elle-même après chaque écoute et à l'ouverture : pas de
// tâche planifiée à configurer. Elle ne fait que supprimer ce qui doit l'être,
// donc l'appeler plusieurs fois ne pose aucun problème.
//
// Aucun secret à ajouter : SUPABASE_URL et SUPABASE_SERVICE_ROLE_KEY sont
// fournis automatiquement par Supabase. « Verify JWT » peut rester ACTIVÉ.
// =====================================================================
import { createClient } from 'npm:@supabase/supabase-js@2';

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  const admin = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, {
    auth: { persistSession: false },
  });
  try {
    const { data, error } = await admin.rpc('voices_to_delete');
    if (error) throw error;
    const paths: string[] = (data || []).map((r: { path: string }) => r.path).filter(Boolean);
    if (paths.length) {
      // Le stockage accepte des lots ; on supprime par paquets de 100
      for (let i = 0; i < paths.length; i += 100) {
        const batch = paths.slice(i, i + 100);
        const { error: e2 } = await admin.storage.from('vocaux').remove(batch);
        if (e2) throw e2;
      }
      const { error: e3 } = await admin.rpc('voices_deleted', { p_paths: paths });
      if (e3) throw e3;
    }
    return new Response(JSON.stringify({ deleted: paths.length }), {
      headers: { ...cors, 'Content-Type': 'application/json' },
    });
  } catch (e) {
    console.error(e);
    return new Response(JSON.stringify({ error: String((e as Error).message || e) }), {
      status: 500, headers: { ...cors, 'Content-Type': 'application/json' },
    });
  }
});
