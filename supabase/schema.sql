-- ============================================================================
--  AUCTION MY CAR — Phase 1 schema (Supabase / PostgreSQL)
--  Run this ONCE in: Supabase Dashboard -> SQL Editor -> New query -> paste -> Run
--
--  What this gives you:
--   - The core v1.1 data model: profiles, auctions, lots, bids, entries,
--     the real 33-band fee schedule, settings.
--   - THE RULES LIVE IN THE DATABASE as functions (place_bid, enter_auction,
--     verify stub, approve/reject, close_auction) so the browser can talk to
--     Supabase directly with the publishable key and still cannot cheat.
--   - Row Level Security on everything; deny-by-default; reads go through
--     controlled functions so VIN/registration stay hidden from unverified users.
-- ============================================================================

-- ---------- enums ----------
create type lot_status  as enum ('draft','pending','rejected','listed','sold','unsold','defaulted');
create type title_cat   as enum ('clean','n','s');
create type auction_sts as enum ('scheduled','live','closed');

-- ---------- profiles (one row per auth user) ----------
create table public.profiles (
  id         uuid primary key references auth.users(id) on delete cascade,
  name       text not null default '',
  phone      text not null default '',
  postcode   text not null default '',
  verified   boolean not null default false,   -- flipped by verify stub now, Stripe Identity in phase 3
  is_admin   boolean not null default false,
  is_master  boolean not null default false,
  created_at timestamptz not null default now()
);

-- auto-create a profile whenever someone signs up
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, name, phone, postcode)
  values (new.id,
          coalesce(new.raw_user_meta_data->>'name',''),
          coalesce(new.raw_user_meta_data->>'phone',''),
          coalesce(new.raw_user_meta_data->>'postcode',''));
  return new;
end $$;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------- auctions ----------
create table public.auctions (
  id        uuid primary key default gen_random_uuid(),
  title     text not null,
  starts_at timestamptz not null,          -- Saturday 08:00
  status    auction_sts not null default 'scheduled',
  created_at timestamptz not null default now()
);

-- ---------- lots ----------
create table public.lots (
  id            uuid primary key default gen_random_uuid(),
  lot_no        int generated always as identity (start with 200),
  seller_id     uuid not null references public.profiles(id),
  auction_id    uuid not null references public.auctions(id),
  make          text not null,
  model         text not null,
  year          int  not null,
  mileage       int  not null default 0,
  reg           text not null default '',
  vin           text not null default '',
  cat           title_cat not null default 'clean',
  fuel          text not null default '',
  transmission  text not null default '',
  engine        text not null default '',
  owners        int,
  mot           text not null default '',
  location      text not null default '',
  description   text not null default '',
  damage        text not null,                          -- the load-bearing declaration
  photos        jsonb not null default '[]',
  start_pence   int  not null check (start_pence > 0),
  reserve_pence int,
  buy_now_pence int,
  featured      boolean not null default false,
  status        lot_status not null default 'pending',
  reject_reason text,
  winner_id     uuid references public.profiles(id),
  winning_bid   uuid,
  payment_deadline timestamptz,
  created_at    timestamptz not null default now()
);
create index lots_auction on public.lots(auction_id, status);

-- ---------- bids (append-only) ----------
create table public.bids (
  id         uuid primary key default gen_random_uuid(),
  lot_id     uuid not null references public.lots(id),
  bidder_id  uuid not null references public.profiles(id),
  amount     int  not null check (amount > 0),          -- pence
  created_at timestamptz not null default now()
);
create index bids_top on public.bids(lot_id, amount desc);

-- ---------- auction entries: the £50 hold + the two consents ----------
create table public.auction_entries (
  id                uuid primary key default gen_random_uuid(),
  auction_id        uuid not null references public.auctions(id),
  user_id           uuid not null references public.profiles(id),
  terms_accepted_at timestamptz not null,
  binding_ack_at    timestamptz not null,
  ip                text not null default '',
  deposit_status    text not null default 'held_stub',  -- real Stripe authorisation in phase 3
  created_at        timestamptz not null default now(),
  unique (auction_id, user_id)
);

-- ---------- the real fee schedule (from Bidding_fee.ods), amounts in pence ----------
create table public.fee_schedule (
  id serial primary key,
  min_pence bigint not null,
  max_pence bigint,                 -- null = open-ended top band
  flat_pence int,                   -- either flat…
  pct numeric(6,4)                  -- …or percentage
);
insert into public.fee_schedule (min_pence,max_pence,flat_pence,pct) values
 (1,4999,500,null),(5000,9999,2000,null),(10000,19999,4500,null),(20000,29999,6500,null),
 (30000,34999,7500,null),(35000,39999,8500,null),(40000,44999,9500,null),(45000,49999,10000,null),
 (50000,54999,10500,null),(55000,59999,11500,null),(60000,69999,12500,null),(70000,79999,14000,null),
 (80000,89999,15500,null),(90000,99999,17000,null),(100000,119999,18500,null),(120000,129999,20500,null),
 (130000,139999,21500,null),(140000,149999,22500,null),(150000,159999,23500,null),(160000,169999,24500,null),
 (170000,179999,26000,null),(180000,199999,27000,null),(200000,239999,30000,null),(240000,249999,32500,null),
 (250000,299999,35000,null),(300000,349999,38500,null),(350000,399999,42500,null),(400000,449999,47000,null),
 (450000,499999,49500,null),(500000,599999,51500,null),(600000,749999,52500,null),(750000,999999,55000,null),
 (1000000,null,null,0.0550);

-- ---------- platform settings (data, never code) ----------
create table public.settings (key text primary key, value jsonb not null);
insert into public.settings (key,value) values
 ('vat',            '{"enabled":false,"rate":0.20}'),
 ('listing_fee',    '2500'), ('featured_fee','1000'), ('featured_cap','21'),
 ('verify_fee',     '500'),  ('deposit','5000'),      ('min_bid','15000'),
 ('timer_standard', '15'),   ('timer_featured','30'),
 ('payment_window_hours','72'), ('collection_fine_per_day','500'), ('collection_cap_days','14');

-- ============================================================================
--  HELPERS
-- ============================================================================
create or replace function public.bid_increment(p int) returns int
language sql immutable as $$
  select case when p < 100000 then 5000        -- < £1,000  -> £50
              when p < 500000 then 10000       -- < £5,000  -> £100
              else 20000 end;                  -- £5,000+   -> £200
$$;

create or replace function public.auction_fee(price_pence bigint) returns bigint
language sql stable as $$
  select coalesce(
    (select case when flat_pence is not null then flat_pence::bigint
                 else round(price_pence * pct)::bigint end
       from public.fee_schedule
      where price_pence >= min_pence and (max_pence is null or price_pence <= max_pence)
      limit 1), 0);
$$;

create or replace function public.is_verified(uid uuid) returns boolean
language sql stable security definer set search_path=public as
$$ select coalesce((select verified from profiles where id = uid), false) $$;

create or replace function public.is_admin(uid uuid) returns boolean
language sql stable security definer set search_path=public as
$$ select coalesce((select is_admin or is_master from profiles where id = uid), false) $$;

-- ============================================================================
--  THE RULES, AS FUNCTIONS (security definer = they run with full rights,
--  so RLS can stay locked while these remain the only doors)
-- ============================================================================

-- --- verification stub: becomes Stripe Identity + £5 in phase 3 ---
create or replace function public.verify_me() returns void
language plpgsql security definer set search_path=public as $$
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  insert into profiles (id, verified) values (auth.uid(), true)
  on conflict (id) do update set verified = true;
end $$;

-- --- enter an auction: records BOTH consents with timestamp + ip ---
create or replace function public.enter_auction(p_auction uuid, p_ip text default '')
returns uuid language plpgsql security definer set search_path=public as $$
declare eid uuid;
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  if not is_verified(auth.uid()) then raise exception 'Verification required before bidding'; end if;
  insert into auction_entries (auction_id, user_id, terms_accepted_at, binding_ack_at, ip)
  values (p_auction, auth.uid(), now(), now(), p_ip)
  on conflict (auction_id, user_id) do update set ip = excluded.ip
  returning id into eid;
  return eid;
end $$;

-- --- create a listing: always lands as PENDING for the target auction ---
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
          p_start_pence, p_reserve_pence, p_buy_now_pence, p_featured, 'pending')
  returning id into lid;
  return lid;                       -- £25 listing payment attaches here in phase 3
end $$;

-- --- admin: approve / reject ---
create or replace function public.approve_listing(p_lot uuid) returns void
language plpgsql security definer set search_path=public as $$
begin
  if not is_admin(auth.uid()) then raise exception 'Admins only'; end if;
  update lots set status='listed', reject_reason=null where id=p_lot and status='pending';
end $$;

create or replace function public.reject_listing(p_lot uuid, p_reason text) returns void
language plpgsql security definer set search_path=public as $$
begin
  if not is_admin(auth.uid()) then raise exception 'Admins only'; end if;
  update lots set status='rejected', reject_reason=p_reason where id=p_lot and status='pending';
end $$;

-- --- THE BID. Row-locked, so two bids on the same car queue safely. ---
create or replace function public.place_bid(p_lot uuid, p_amount int)
returns table (bid_id uuid, new_price int) language plpgsql security definer set search_path=public as $$
declare l lots%rowtype; top int; min_needed int; min_first int; nb uuid;
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  if not is_verified(auth.uid()) then raise exception 'Verification required before bidding'; end if;

  select * into l from lots where id = p_lot for update;      -- <- the lock
  if not found then raise exception 'Lot not found'; end if;
  if l.status <> 'listed' then raise exception 'This lot is not open for bidding'; end if;
  if l.seller_id = auth.uid() then raise exception 'You cannot bid on your own car'; end if;

  if not exists (select 1 from auction_entries
                  where auction_id = l.auction_id and user_id = auth.uid())
    then raise exception 'Enter the auction first (deposit + consents)'; end if;

  select max(amount) into top from bids where lot_id = p_lot;
  select (value)::int into min_first from settings where key='min_bid';
  min_needed := case when top is null then greatest(l.start_pence, min_first)
                     else top + bid_increment(top) end;
  if p_amount < min_needed then
    raise exception 'Bid must be at least £%', to_char(min_needed/100.0,'FM999,999,990.00');
  end if;

  insert into bids (lot_id, bidder_id, amount) values (p_lot, auth.uid(), p_amount)
  returning id into nb;
  return query select nb, p_amount;
end $$;

-- --- read functions: what unverified eyes may and may not see ---
create or replace function public.browse_lots()
returns table (id uuid, lot_no int, make text, model text, year int, mileage int,
               reg text, cat title_cat, fuel text, engine text, location text,
               featured boolean, buy_now_pence int, has_reserve boolean,
               current_pence bigint, bid_count bigint, auction_id uuid, starts_at timestamptz)
language sql stable security definer set search_path=public as $$
  select l.id, l.lot_no, l.make, l.model, l.year, l.mileage,
         case when is_verified(auth.uid()) then l.reg else '' end,
         l.cat, l.fuel, l.engine, l.location, l.featured, l.buy_now_pence,
         (l.reserve_pence is not null),
         coalesce((select max(b.amount) from bids b where b.lot_id=l.id), l.start_pence)::bigint,
         (select count(*) from bids b where b.lot_id=l.id),
         l.auction_id, a.starts_at
    from lots l join auctions a on a.id=l.auction_id
   where l.status = 'listed'
   order by a.starts_at, l.featured desc, l.created_at;
$$;

create or replace function public.lot_details(p_lot uuid)
returns table (id uuid, lot_no int, make text, model text, year int, mileage int,
               reg text, vin text, cat title_cat, fuel text, transmission text, engine text,
               owners int, mot text, location text, description text, damage text,
               featured boolean, buy_now_pence int, has_reserve boolean,
               current_pence bigint, min_next_pence bigint, bid_count bigint,
               auction_id uuid, starts_at timestamptz, seller_is_me boolean)
language sql stable security definer set search_path=public as $$
  select l.id, l.lot_no, l.make, l.model, l.year, l.mileage,
         case when is_verified(auth.uid()) then l.reg else '' end,
         case when is_verified(auth.uid()) then l.vin else '' end,
         l.cat,
         l.fuel,
         case when is_verified(auth.uid()) then l.transmission else '' end,
         l.engine,
         case when is_verified(auth.uid()) then l.owners else null end,
         case when is_verified(auth.uid()) then l.mot else '' end,
         l.location, l.description,
         case when is_verified(auth.uid()) then l.damage else '' end,
         l.featured, l.buy_now_pence, (l.reserve_pence is not null),
         coalesce((select max(b.amount) from bids b where b.lot_id=l.id), l.start_pence)::bigint,
         coalesce((select max(b.amount)+bid_increment(max(b.amount)) from bids b where b.lot_id=l.id),
                  greatest(l.start_pence,15000))::bigint,
         (select count(*) from bids b where b.lot_id=l.id),
         l.auction_id, a.starts_at, (l.seller_id = auth.uid())
    from lots l join auctions a on a.id=l.auction_id
   where l.id = p_lot and (l.status='listed' or l.seller_id=auth.uid());
$$;

create or replace function public.lot_bid_history(p_lot uuid)
returns table (masked text, amount int, created_at timestamptz)
language sql stable security definer set search_path=public as $$
  select left(coalesce(nullif(p.name,''),'B'),1) || '***' || right(b.bidder_id::text,1),
         b.amount, b.created_at
    from bids b join profiles p on p.id=b.bidder_id
   where b.lot_id=p_lot order by b.amount desc limit 10;
$$;

create or replace function public.my_bids()
returns table (lot_id uuid, lot_no int, make text, model text, year int,
               my_best int, current_top bigint, i_lead boolean, lot_status lot_status)
language sql stable security definer set search_path=public as $$
  select l.id, l.lot_no, l.make, l.model, l.year,
         max(b.amount) filter (where b.bidder_id = auth.uid()),
         (select max(amount) from bids b2 where b2.lot_id = l.id)::bigint,
         (select bidder_id from bids b3 where b3.lot_id = l.id order by amount desc, created_at asc limit 1) = auth.uid(),
         l.status
    from bids b join lots l on l.id = b.lot_id
   where b.bidder_id = auth.uid()
   group by l.id
   order by max(b.created_at) desc;
$$;

create or replace function public.my_listings()
returns setof lots language sql stable security definer set search_path=public as
$$ select * from lots where seller_id = auth.uid() order by created_at desc $$;

-- --- the close: idempotent, one pass, winners decided exactly once ---
create or replace function public.close_auction(p_auction uuid) returns void
language plpgsql security definer set search_path=public as $$
declare l record; top record;
begin
  if not is_admin(auth.uid()) then raise exception 'Admins only'; end if;
  if (select status from auctions where id=p_auction) = 'closed'
    then raise exception 'Auction already closed'; end if;
  for l in select * from lots where auction_id=p_auction and status='listed' for update loop
    select * into top from bids where lot_id=l.id order by amount desc limit 1;
    if top.id is not null and (l.reserve_pence is null or top.amount >= l.reserve_pence) then
      update lots set status='sold', winner_id=top.bidder_id, winning_bid=top.id,
                      payment_deadline = now() + interval '72 hours'
       where id=l.id;
    else
      update lots set status='unsold' where id=l.id;   -- negotiation flow arrives in phase 2
    end if;
  end loop;
  update auctions set status='closed' where id=p_auction;
  -- deposits: stub-released here; real Stripe authorisation-cancel in phase 3
  update auction_entries set deposit_status='released_stub'
   where auction_id=p_auction
     and user_id not in (select winner_id from lots where auction_id=p_auction and winner_id is not null);
end $$;

-- ============================================================================
--  ROW LEVEL SECURITY — lock everything; the functions above are the doors
-- ============================================================================
alter table public.profiles        enable row level security;
alter table public.auctions        enable row level security;
alter table public.lots            enable row level security;
alter table public.bids            enable row level security;
alter table public.auction_entries enable row level security;
alter table public.fee_schedule    enable row level security;
alter table public.settings        enable row level security;

create policy "own profile read"   on public.profiles for select using (id = auth.uid());
create policy "own profile update" on public.profiles for update
  using (id = auth.uid())
  with check (id = auth.uid() and verified = (select verified from public.profiles where id=auth.uid())
              and is_admin = (select is_admin from public.profiles where id=auth.uid())
              and is_master = (select is_master from public.profiles where id=auth.uid()));
create policy "auctions readable"  on public.auctions for select using (true);
create policy "fees readable"      on public.settings  for select using (true);
create policy "bands readable"     on public.fee_schedule for select using (true);
create policy "own entries read"   on public.auction_entries for select using (user_id = auth.uid());
-- lots + bids: NO direct policies -> unreachable except via the functions above.

-- ---------- grants: required because "auto-expose new tables" is (correctly) OFF.
-- RLS still decides WHICH rows; these decide WHETHER the roles may ask at all.
grant usage on schema public to anon, authenticated;
grant select on public.auctions, public.settings, public.fee_schedule to anon, authenticated;
grant select on public.profiles, public.auction_entries to authenticated;
-- lots and bids deliberately get NO grants: the security-definer functions are the only doors.

-- ---------- deliberate API grants ("auto-expose new tables" is OFF, so we grant manually) ----------
grant usage on schema public to anon, authenticated;
grant select on public.profiles        to authenticated;  -- RLS: own row only
grant select on public.auction_entries to authenticated;  -- RLS: own rows only
grant select on public.auctions        to anon, authenticated;
grant select on public.settings        to anon, authenticated;
grant select on public.fee_schedule    to anon, authenticated;
-- lots and bids: deliberately NO grants — functions are the only doors.

-- ---------- seed: the first Saturday auction ----------
insert into public.auctions (title, starts_at)
values ('Weekly auction',
        (date_trunc('week', now()) + interval '5 days' + interval '8 hours'
         + case when (date_trunc('week', now()) + interval '5 days' + interval '8 hours') <= now()
                then interval '7 days' else interval '0' end));

-- ============================================================================
--  AFTER RUNNING THIS: make yourself master admin (replace the email):
--    update public.profiles set is_admin=true, is_master=true
--     where id = (select id from auth.users where email='YOUR-EMAIL-HERE');
-- ============================================================================
