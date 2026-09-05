-- ============================================================================
--  AUCTION MY CAR — PHASE 3 (part 1): payments foundation + the listing fee
--  Run ONCE in Supabase SQL Editor (phases 1 + 2 must already exist).
--
--  Money model: the browser NEVER talks to Stripe with secrets and NEVER
--  decides that something was paid. Payment truth arrives only through the
--  stripe-webhook Edge Function, which uses the service-role key — so none
--  of the functions below that mark things paid are callable from a browser.
-- ============================================================================

-- ---------- the payments ledger ----------
create table public.payments (
  id                    uuid primary key default gen_random_uuid(),
  user_id               uuid not null references public.profiles(id),
  lot_id                uuid references public.lots(id),
  auction_id            uuid references public.auctions(id),
  kind                  text not null,          -- listing | verification | deposit | checkout | payout
  amount_pence          int  not null,
  currency              text not null default 'gbp',
  stripe_session_id     text,
  stripe_payment_intent text,
  status                text not null default 'created',  -- created | paid | failed | refunded | released | captured
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now()
);
create index payments_user on public.payments(user_id, created_at desc);
create unique index payments_session on public.payments(stripe_session_id) where stripe_session_id is not null;

alter table public.payments enable row level security;
create policy "own payments read" on public.payments for select using (user_id = auth.uid());
grant select on public.payments to authenticated;
-- no insert/update grants: only the service role (webhook) writes here.

-- ---------- stripe ids where they'll be needed ----------
alter table public.profiles add column if not exists stripe_customer_id text;
alter table public.profiles add column if not exists stripe_account_id  text;   -- Connect (sellers)
alter table public.auction_entries add column if not exists stripe_pi_id text;  -- the £50 authorisation

-- ---------- listings now WAIT FOR PAYMENT as drafts ----------
-- create_listing lands the lot as 'draft'; the webhook promotes it to 'pending'
-- (the approval queue) once the £25/£35 has actually been paid.
create or replace function public.create_listing(
  p_auction uuid, p_make text, p_model text, p_year int, p_mileage int,
  p_reg text, p_vin text, p_cat title_cat, p_fuel text, p_trans text, p_engine text,
  p_owners int, p_mot text, p_location text, p_description text, p_damage text,
  p_start_pence int, p_reserve_pence int default null, p_buy_now_pence int default null,
  p_featured boolean default false
) returns uuid language plpgsql security definer set search_path=public as $$
declare lid uuid; feat_count int; cap int;
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  if not is_verified(auth.uid()) then raise exception 'Verification required before listing'; end if;
  if coalesce(trim(p_damage),'') = '' then raise exception 'Damage declaration is required'; end if;
  if p_featured then
    select (value)::int into cap from settings where key='featured_cap';
    select count(*) into feat_count from lots where auction_id=p_auction and featured and status in ('pending','listed');
    if feat_count >= cap then raise exception 'All % featured slots for this auction are taken', cap; end if;
  end if;
  insert into lots (seller_id, auction_id, make, model, year, mileage, reg, vin, cat, fuel,
                    transmission, engine, owners, mot, location, description, damage,
                    start_pence, reserve_pence, buy_now_pence, featured, status)
  values (auth.uid(), p_auction, p_make, p_model, p_year, p_mileage, upper(p_reg), p_vin, p_cat,
          p_fuel, p_trans, p_engine, p_owners, p_mot, p_location, p_description, p_damage,
          p_start_pence, p_reserve_pence, p_buy_now_pence, p_featured, 'draft')
  returning id into lid;
  return lid;
end $$;

-- ---------- what the listing costs (read by the Edge Function, server-side) ----------
create or replace function public.listing_fee_pence(p_lot uuid) returns int
language sql stable security definer set search_path=public as $$
  select (select (value)::int from settings where key='listing_fee')
       + case when (select featured from lots where id=p_lot)
              then (select (value)::int from settings where key='featured_fee') else 0 end;
$$;

-- ---------- webhook-only: mark a listing paid and promote it to the queue ----------
-- No grants to anon/authenticated: only the service role (the webhook) can call it.
create or replace function public.mark_listing_paid(
  p_lot uuid, p_session text, p_pi text, p_amount int) returns void
language plpgsql security definer set search_path=public as $$
declare l lots%rowtype;
begin
  select * into l from lots where id=p_lot for update;
  if not found then raise exception 'Lot not found'; end if;
  if l.status = 'draft' then
    update lots set status='pending' where id=p_lot;
  end if;
  insert into payments (user_id, lot_id, auction_id, kind, amount_pence,
                        stripe_session_id, stripe_payment_intent, status)
  values (l.seller_id, p_lot, l.auction_id, 'listing', p_amount, p_session, p_pi, 'paid')
  on conflict (stripe_session_id) where stripe_session_id is not null
    do update set status='paid', updated_at=now();
end $$;
revoke execute on function public.mark_listing_paid(uuid, text, text, int) from public, anon, authenticated;

-- ---------- my_listings already returns drafts (setof lots) — nothing to change;
--            the seller dashboard shows 'draft' as "awaiting payment".
