/* ============================================================
   AUCTION MY CAR — live backend adapter (phase 1)
   Talks to Supabase directly with the PUBLISHABLE key only.
   All rules are enforced inside the database (see supabase/schema.sql),
   so nothing here can be abused even though it runs in the browser.
   Load AFTER assets/amc.js and after the supabase-js CDN script.
   ============================================================ */
const SUPABASE_URL = 'https://YOUR_PROJECT_ID.supabase.co';
const SUPABASE_KEY = 'YOUR_SUPABASE_PUBLISHABLE_KEY';

const sb = window.supabase.createClient(SUPABASE_URL, SUPABASE_KEY);

/* --- session recovery: pick up tokens from email-confirm redirects --- */
(async function recoverSession(){
  // Supabase appends #access_token=...&refresh_token=... after email confirmation.
  // The client picks those up automatically IF we give it a moment to do so.
  const { data:{ session } } = await sb.auth.getSession();
  if (session) {
    // sync the lightweight local AUTH state the pages read for UI
    try {
      const { data: profile } = await sb.from('profiles').select('*').eq('id', session.user.id).single();
      const name = (profile && profile.name) || session.user.email.split('@')[0];
      AUTH.login(name, session.user.email);
      if (profile && profile.verified) AUTH.verify();
    } catch(e) { /* profile may not exist yet if trigger hasn't fired */ }
  }
  // listen for future sign-in / sign-out so every tab stays in sync
  sb.auth.onAuthStateChange(async (event, session) => {
    if (event === 'SIGNED_IN' && session) {
      try {
        const { data: profile } = await sb.from('profiles').select('*').eq('id', session.user.id).single();
        AUTH.login((profile && profile.name) || session.user.email.split('@')[0], session.user.email);
        if (profile && profile.verified) AUTH.verify();
      } catch(e) {}
    }
    if (event === 'SIGNED_OUT') { AUTH.logout(); }
  });
})();

const API = {
  /* ---------- auth ---------- */
  async register(name, email, password, phone, postcode){
    const { data, error } = await sb.auth.signUp({
      email, password, options: { data: { name, phone, postcode } }
    });
    if (error) throw error;
    return data;
  },
  async login(email, password){
    const { data, error } = await sb.auth.signInWithPassword({ email, password });
    if (error) throw error;
    return data;
  },
  async logout(){ await sb.auth.signOut(); },
  async me(){
    const { data:{ user } } = await sb.auth.getUser();
    if (!user) return null;
    const { data: profile } = await sb.from('profiles').select('*').eq('id', user.id).single();
    return { user, profile };
  },

  /* ---------- verification (stub — Stripe Identity + £5 in phase 3) ---------- */
  async verifyMe(){
    const { error } = await sb.rpc('verify_me');
    if (error) throw error;
  },

  /* ---------- auctions & entry (consents recorded server-side) ---------- */
  async nextAuction(){
    const { data, error } = await sb.from('auctions').select('*')
      .neq('status','closed').order('starts_at').limit(1).single();
    if (error) throw error;
    return data;
  },
  async enterAuction(auctionId){
    const { data, error } = await sb.rpc('enter_auction', { p_auction: auctionId });
    if (error) throw error;
    return data;
  },

  /* ---------- lots ---------- */
  async browse(){
    const { data, error } = await sb.rpc('browse_lots');
    if (error) throw error;
    return data || [];
  },
  async lot(id){
    const { data, error } = await sb.rpc('lot_details', { p_lot: id });
    if (error) throw error;
    return data && data[0];
  },
  async bidHistory(id){
    const { data } = await sb.rpc('lot_bid_history', { p_lot: id });
    return data || [];
  },
  async myListings(){
    const { data, error } = await sb.rpc('my_listings');
    if (error) throw error;
    return data || [];
  },
  async createListing(f){
    const { data, error } = await sb.rpc('create_listing', {
      p_auction: f.auctionId, p_make: f.make, p_model: f.model, p_year: +f.year||2018,
      p_mileage: +f.miles||0, p_reg: f.reg||'', p_vin: f.vin||'', p_cat: f.cat||'clean',
      p_fuel: f.fuel||'', p_trans: f.trans||'', p_engine: f.engine||'', p_owners: +f.owners||null,
      p_mot: f.mot||'', p_location: f.loc||'', p_description: f.desc||'', p_damage: f.damage,
      p_start_pence: Math.round((+f.start||0)*100),
      p_reserve_pence: f.reserve ? Math.round(+f.reserve*100) : null,
      p_buy_now_pence: f.buynow ? Math.round(+f.buynow*100) : null,
      p_featured: !!f.feat
    });
    if (error) throw error;
    return data;
  },

  /* ---------- bidding (row-locked in the database) ---------- */
  async placeBid(lotId, pounds){
    const { data, error } = await sb.rpc('place_bid', {
      p_lot: lotId, p_amount: Math.round(pounds*100)
    });
    if (error) throw error;
    return data && data[0];
  },

  /* ---------- realtime: the phase-2 seam, already usable ---------- */
  watchBids(lotId, onBid){
    return sb.channel('bids-'+lotId)
      .on('postgres_changes',
          { event:'insert', schema:'public', table:'bids', filter:'lot_id=eq.'+lotId },
          payload => onBid(payload.new))
      .subscribe();
  }
};
window.API = API;

/* Map a live database lot onto the shape the existing card renderer expects */
function liveLotToCard(r){
  return {
    id: r.id, live: true, no: String(r.lot_no),
    make: r.make, model: r.model, year: r.year, miles: r.mileage,
    reg: r.reg || '•••• •••', cat: r.cat, fuel: r.fuel,
    cur: Math.round(r.current_pence/100), bids: Number(r.bid_count),
    featured: r.featured, buyNow: r.buy_now_pence ? Math.round(r.buy_now_pence/100) : null,
    reserve: r.has_reserve ? 1 : null, week: 0, loc: r.location, eng: r.engine
  };
}
