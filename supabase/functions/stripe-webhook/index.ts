// =====================================================================
// Petit Bonbon — webhook Stripe
// Débloque l'accès d'un compte quand le paiement de 0,99 € est confirmé.
//
// Secret à définir dans Supabase › Edge Functions › Secrets :
//   STRIPE_WEBHOOK_SECRET  (whsec_…, fourni par Stripe quand tu crées le webhook)
// SUPABASE_URL et SUPABASE_SERVICE_ROLE_KEY sont fournis automatiquement par Supabase.
//
// Important : désactiver « Verify JWT » pour cette fonction (Stripe n'envoie
// pas de jeton Supabase ; la sécurité vient de la signature Stripe vérifiée ici).
// =====================================================================
import Stripe from 'npm:stripe@16';
import { createClient } from 'npm:@supabase/supabase-js@2';

// Aucune clé secrète Stripe n'est nécessaire pour vérifier une signature.
const stripe = new Stripe(Deno.env.get('STRIPE_SECRET_KEY') ?? 'sk_not_needed', {
  httpClient: Stripe.createFetchHttpClient(),
});
const cryptoProvider = Stripe.createSubtleCryptoProvider();
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

Deno.serve(async (req) => {
  if (req.method !== 'POST') return new Response('Method not allowed', { status: 405 });
  const signature = req.headers.get('stripe-signature');
  const secret = Deno.env.get('STRIPE_WEBHOOK_SECRET');
  if (!signature || !secret) return new Response('Missing signature or secret', { status: 400 });

  const body = await req.text();
  let event: Stripe.Event;
  try {
    event = await stripe.webhooks.constructEventAsync(body, signature, secret, undefined, cryptoProvider);
  } catch (_err) {
    return new Response('Invalid signature', { status: 400 });
  }

  if (event.type === 'checkout.session.completed' || event.type === 'checkout.session.async_payment_succeeded') {
    const session = event.data.object as Stripe.Checkout.Session;
    const userId = session.client_reference_id;
    if (session.payment_status === 'paid' && userId && UUID.test(userId)) {
      const admin = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, {
        auth: { persistSession: false },
      });
      const { error } = await admin
        .from('profiles')
        .update({ paid_at: new Date().toISOString() })
        .eq('id', userId)
        .is('paid_at', null);
      if (error) {
        console.error('profile update failed', error);
        return new Response('Database error', { status: 500 }); // Stripe réessaiera
      }
    } else {
      console.warn('checkout without valid client_reference_id', session.id);
    }
  }
  return new Response(JSON.stringify({ received: true }), { headers: { 'Content-Type': 'application/json' } });
});
