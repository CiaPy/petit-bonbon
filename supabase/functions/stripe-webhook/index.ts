// =====================================================================
// Petit Bonbon — webhook Stripe
// - Abonnement Premium (Stripe Billing) : active, met à jour ou coupe Premium.
// - Accès payant unique (ancien mode 0,99 €, désactivé par défaut) : débloque l'accès.
//
// Secret à définir dans Supabase › Edge Functions › Secrets :
//   STRIPE_WEBHOOK_SECRET  (whsec_…, fourni par Stripe quand tu crées le webhook)
// SUPABASE_URL et SUPABASE_SERVICE_ROLE_KEY sont fournis automatiquement par Supabase.
//
// « Verify JWT » doit être DÉSACTIVÉ pour cette fonction : Stripe n'envoie pas
// de jeton Supabase, la sécurité vient de la signature Stripe vérifiée ici.
//
// Événements à cocher dans Stripe :
//   checkout.session.completed
//   checkout.session.async_payment_succeeded
//   customer.subscription.created
//   customer.subscription.updated
//   customer.subscription.deleted
// =====================================================================
import Stripe from 'npm:stripe@16';
import { createClient } from 'npm:@supabase/supabase-js@2';

// Aucune clé secrète Stripe n'est nécessaire : on ne fait que vérifier des signatures.
const stripe = new Stripe(Deno.env.get('STRIPE_SECRET_KEY') ?? 'sk_not_needed', {
  httpClient: Stripe.createFetchHttpClient(),
});
const cryptoProvider = Stripe.createSubtleCryptoProvider();
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

const admin = () =>
  createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, {
    auth: { persistSession: false },
  });

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } });

// Fin de la période payée : selon la version d'API Stripe, elle est sur l'abonnement
// ou sur sa première ligne.
function periodEnd(sub: any): string | null {
  const ts = sub.current_period_end ?? sub.items?.data?.[0]?.current_period_end ?? null;
  return ts ? new Date(ts * 1000).toISOString() : null;
}
const idOf = (x: unknown) => (typeof x === 'string' ? x : (x as any)?.id ?? null);

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

  const db = admin();

  // ---- Fin d'un paiement Checkout (Payment Link) ----
  if (event.type === 'checkout.session.completed' || event.type === 'checkout.session.async_payment_succeeded') {
    const session = event.data.object as Stripe.Checkout.Session;
    const userId = session.client_reference_id;
    if (!userId || !UUID.test(userId)) {
      console.warn('checkout sans client_reference_id valide', session.id);
      return json({ received: true });
    }

    if (session.mode === 'subscription') {
      const { error } = await db.from('profiles').update({
        stripe_customer_id: idOf(session.customer),
        sub_id: idOf(session.subscription),
        sub_status: 'active',
        sub_cancel_at_end: false,
      }).eq('id', userId);
      if (error) { console.error(error); return new Response('Database error', { status: 500 }); }
    } else if (session.payment_status === 'paid') {
      const { error } = await db.from('profiles').update({ paid_at: new Date().toISOString() })
        .eq('id', userId).is('paid_at', null);
      if (error) { console.error(error); return new Response('Database error', { status: 500 }); }
    }
    return json({ received: true });
  }

  // ---- Vie de l'abonnement : création, renouvellement, résiliation, échec de paiement ----
  if (event.type.startsWith('customer.subscription.')) {
    const sub = event.data.object as Stripe.Subscription;
    const status = event.type === 'customer.subscription.deleted' ? 'canceled' : sub.status;
    const { data, error } = await db.from('profiles').update({
      sub_id: sub.id,
      sub_status: status,
      sub_period_end: periodEnd(sub),
      sub_cancel_at_end: !!sub.cancel_at_period_end,
    }).eq('stripe_customer_id', idOf(sub.customer)).select('id');
    if (error) { console.error(error); return new Response('Database error', { status: 500 }); }
    // L'abonnement peut arriver avant la fin du Checkout : on demande à Stripe de réessayer plus tard.
    if (!data || data.length === 0) {
      if (event.type === 'customer.subscription.deleted') return json({ received: true, ignored: true });
      return new Response('Customer not linked yet', { status: 409 });
    }
    return json({ received: true });
  }

  return json({ received: true, ignored: event.type });
});
