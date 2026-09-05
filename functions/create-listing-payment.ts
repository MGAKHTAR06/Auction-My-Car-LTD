// ============================================================================
// Edge Function: create-listing-payment
// Called by the browser (logged-in seller). Creates a Stripe Checkout Session
// for the £25/£35 listing fee, computed SERVER-SIDE from the settings table.
// Deploy name: create-listing-payment  (Verify JWT: ON — default)
// Secrets needed: STRIPE_SECRET_KEY
// ============================================================================
import Stripe from 'https://esm.sh/stripe@14.25.0?target=denonext';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const stripe = new Stripe(Deno.env.get('STRIPE_SECRET_KEY')!, {
  apiVersion: '2024-04-10',
  httpClient: Stripe.createFetchHttpClient(),
});

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};
const json = (o: unknown, status = 200) =>
  new Response(JSON.stringify(o), { status, headers: { ...cors, 'Content-Type': 'application/json' } });

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  try {
    const { lot_id, return_base } = await req.json();

    // who is calling? (their own JWT, passed through)
    const supa = createClient(
      Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_ANON_KEY')!,
      { global: { headers: { Authorization: req.headers.get('Authorization')! } } });
    const { data: { user } } = await supa.auth.getUser();
    if (!user) return json({ error: 'Not signed in' }, 401);

    // service client: read the draft lot + the fee the DATABASE says is due
    const admin = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
    const { data: lot } = await admin.from('lots')
      .select('id,seller_id,status,make,model,year,featured').eq('id', lot_id).single();
    if (!lot || lot.seller_id !== user.id) return json({ error: 'Not your listing' }, 403);
    if (lot.status !== 'draft') return json({ error: 'This listing is not awaiting payment' }, 400);

    const { data: fee, error: feeErr } = await admin.rpc('listing_fee_pence', { p_lot: lot_id });
    if (feeErr || !fee) return json({ error: 'Could not price the listing' }, 500);

    const base = String(return_base || '').replace(/\/+$/, '');
    const session = await stripe.checkout.sessions.create({
      mode: 'payment',
      payment_method_types: ['card'],
      line_items: [{
        quantity: 1,
        price_data: {
          currency: 'gbp',
          unit_amount: fee,
          product_data: {
            name: `Listing fee — ${lot.year} ${lot.make} ${lot.model}${lot.featured ? ' (★ featured)' : ''}`,
            description: 'Includes review of your listing before it goes live. Non-refundable.',
          },
        },
      }],
      metadata: { kind: 'listing', lot_id: String(lot_id), user_id: user.id },
      success_url: `${base}/seller.html?paid=1`,
      cancel_url: `${base}/seller.html?cancelled=1`,
    });

    return json({ url: session.url });
  } catch (e) {
    return json({ error: (e as Error).message }, 400);
  }
});
