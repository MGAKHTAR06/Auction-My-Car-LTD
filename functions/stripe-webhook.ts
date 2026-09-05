// ============================================================================
// Edge Function: stripe-webhook
// Called by STRIPE (not by browsers). Verifies the signature, then tells the
// database what really happened. This is the ONLY source of payment truth.
// Deploy name: stripe-webhook  (Verify JWT: OFF — Stripe has no Supabase JWT)
// Secrets needed: STRIPE_SECRET_KEY, STRIPE_WEBHOOK_SECRET
// ============================================================================
import Stripe from 'https://esm.sh/stripe@14.25.0?target=denonext';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const stripe = new Stripe(Deno.env.get('STRIPE_SECRET_KEY')!, {
  apiVersion: '2024-04-10',
  httpClient: Stripe.createFetchHttpClient(),
});
const cryptoProvider = Stripe.createSubtleCryptoProvider();

Deno.serve(async (req) => {
  const signature = req.headers.get('stripe-signature');
  const body = await req.text();

  let event: Stripe.Event;
  try {
    event = await stripe.webhooks.constructEventAsync(
      body, signature!, Deno.env.get('STRIPE_WEBHOOK_SECRET')!, undefined, cryptoProvider);
  } catch (e) {
    return new Response(`Signature verification failed: ${(e as Error).message}`, { status: 400 });
  }

  const admin = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);

  if (event.type === 'checkout.session.completed') {
    const s = event.data.object as Stripe.Checkout.Session;
    if (s.metadata?.kind === 'listing' && s.metadata.lot_id) {
      const { error } = await admin.rpc('mark_listing_paid', {
        p_lot: s.metadata.lot_id,
        p_session: s.id,
        p_pi: String(s.payment_intent ?? ''),
        p_amount: s.amount_total ?? 0,
      });
      if (error) return new Response('DB error: ' + error.message, { status: 500 });
    }
    // deposit / checkout / verification kinds attach here in the next slices
  }

  return new Response(JSON.stringify({ received: true }), {
    headers: { 'Content-Type': 'application/json' },
  });
});
