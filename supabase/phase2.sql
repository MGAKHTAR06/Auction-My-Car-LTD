-- ============================================================================
--  AUCTION MY CAR — PHASE 2: the live Saturday auction engine
--  Run ONCE in Supabase SQL Editor (your phase-1 schema must already exist).
--
--  What this adds:
--   - Auto-start at the scheduled time (8AM Saturday) with a per-week SKIP switch
--   - Server-authoritative soft-close: hammer_at lives in the database;
--     every bid resets it (30s featured / 15s standard); nobody's browser
--     decides anything
--   - Sequential hammering: when the timer dies the lot settles (SOLD/UNSOLD),
--     the next lot goes live automatically, and the event closes after the last
--   - hammer_current() is idempotent and callable by anyone — plus a cron
--     backstop so the auction advances even with zero browsers open
-- ============================================================================

-- ---------- new columns ----------
alter table public.auctions add column if not exists skipped     boolean not null default false;
alter table public.auctions add column if not exists current_lot uuid references public.lots(id);
alter table public.auctions add column if not exists hammer_at   timestamptz;
alter table public.lots     add column if not exists run_order   int;

-- ---------- timer for a lot: 30s featured / 15s standard (+5s breather) ----------
create or replace function public.lot_timer_secs(p_featured boolean) returns int
language sql stable as $$
  select case when p_featured
              then coalesce((select (value)::int from public.settings where key='timer_featured'),30)
              else coalesce((select (value)::int from public.settings where key='timer_standard'),15) end;
$$;

-- ---------- internal starter (NOT callable from the browser) ----------
create or replace function public._start_auction(p_auction uuid) returns void
language plpgsql security definer set search_path=public as $$
declare first_lot record;
begin
  -- lock the auction row; only a scheduled, non-skipped auction can start
  perform 1 from auctions where id=p_auction and status='scheduled' and not skipped for update;
  if not found then return; end if;

  -- running order: featured first (first-paid-first-placed = earliest created), then the rest
  with ordered as (
    select id, row_number() over (order by featured desc, created_at asc) rn
      from lots where auction_id=p_auction and status='listed')
  update lots l set run_order=o.rn from ordered o where l.id=o.id;

  select * into first_lot from lots
   where auction_id=p_auction and status='listed'
   order by run_order limit 1;

  if first_lot.id is null then
    update auctions set status='closed' where id=p_auction;   -- nothing to sell
    return;
  end if;

  update auctions
     set status='live',
         current_lot=first_lot.id,
         hammer_at = now() + make_interval(secs => lot_timer_secs(first_lot.featured) + 5)
   where id=p_auction;
end $$;
revoke execute on function public._start_auction(uuid) from public, anon, authenticated;

-- ---------- admin "start now" + the skip switch ----------
create or replace function public.start_auction(p_auction uuid) returns void
language plpgsql security definer set search_path=public as $$
begin
  if not is_admin(auth.uid()) then raise exception 'Admins only'; end if;
  perform public._start_auction(p_auction);
end $$;

create or replace function public.set_auction_skipped(p_auction uuid, p_skip boolean) returns void
language plpgsql security definer set search_path=public as $$
begin
  if not is_admin(auth.uid()) then raise exception 'Admins only'; end if;
  update auctions set skipped=p_skip where id=p_auction and status='scheduled';
end $$;

-- ---------- auto-start: fires from cron every minute ----------
create or replace function public.auction_autostart() returns void
language plpgsql security definer set search_path=public as $$
declare a record;
begin
  for a in select id from auctions where status='scheduled' and not skipped and starts_at<=now() loop
    perform public._start_auction(a.id);
  end loop;
end $$;
revoke execute on function public.auction_autostart() from public, anon, authenticated;

-- ---------- keep the calendar filled: next 4 Saturdays always exist ----------
create or replace function public.schedule_next_auctions() returns void
language plpgsql security definer set search_path=public as $$
declare d timestamptz; i int;
begin
  for i in 0..3 loop
    d := date_trunc('week', now()) + interval '5 days' + interval '8 hours' + (i * interval '7 days');
    if d <= now() then d := d + interval '7 days'; end if;
    if not exists (select 1 from auctions where starts_at = d) then
      insert into auctions (title, starts_at)
      values ('Auction — ' || to_char(d,'DD Mon YYYY'), d);
    end if;
  end loop;
end $$;
revoke execute on function public.schedule_next_auctions() from public, anon, authenticated;

-- ---------- REWRITTEN place_bid: live-aware, deadlock-safe lock order ----------
-- Lock order is ALWAYS auction -> lot (hammer_current uses the same order).
create or replace function public.place_bid(p_lot uuid, p_amount int)
returns table (bid_id uuid, new_price int) language plpgsql security definer set search_path=public as $$
declare l lots%rowtype; a auctions%rowtype; top int; min_needed int; min_first int; nb uuid;
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  if not is_verified(auth.uid()) then raise exception 'Verification required before bidding'; end if;

  select * into a from auctions where id=(select auction_id from lots where id=p_lot) for update;
  if not found then raise exception 'Lot not found'; end if;

  select * into l from lots where id = p_lot for update;
  if l.status <> 'listed' then raise exception 'This lot is not open for bidding'; end if;
  if l.seller_id = auth.uid() then raise exception 'You cannot bid on your own car'; end if;

  if not exists (select 1 from auction_entries
                  where auction_id = l.auction_id and user_id = auth.uid())
    then raise exception 'Enter the auction first (deposit + consents)'; end if;

  -- during the live event, the lot on the block closes the instant its timer dies
  if a.status='live' and a.current_lot = l.id and a.hammer_at is not null and now() >= a.hammer_at then
    raise exception 'Too late — this lot has hammered';
  end if;

  select max(amount) into top from bids where lot_id = p_lot;
  select (value)::int into min_first from settings where key='min_bid';
  min_needed := case when top is null then greatest(l.start_pence, min_first)
                     else top + bid_increment(top) end;
  if p_amount < min_needed then
    raise exception 'Bid must be at least £%', to_char(min_needed/100.0,'FM999,999,990.00');
  end if;

  insert into bids (lot_id, bidder_id, amount) values (p_lot, auth.uid(), p_amount)
  returning id into nb;

  -- THE SOFT CLOSE: a bid on the live lot resets its hammer timer in full
  if a.status='live' and a.current_lot = l.id then
    update auctions set hammer_at = now() + make_interval(secs => lot_timer_secs(l.featured))
     where id = a.id;
  end if;

  return query select nb, p_amount;
end $$;

-- ---------- THE HAMMER: settle the current lot, advance to the next ----------
-- Idempotent + callable by anyone: it only acts if the deadline truly passed,
-- under a row lock, so a thousand simultaneous calls settle the lot exactly once.
create or replace function public.hammer_current(p_auction uuid) returns jsonb
language plpgsql security definer set search_path=public as $$
declare a auctions%rowtype; l lots%rowtype; top record; nxt record; sold boolean;
begin
  select * into a from auctions where id=p_auction for update;
  if not found or a.status<>'live' or a.current_lot is null then return jsonb_build_object('acted',false); end if;
  if a.hammer_at is null or now() < a.hammer_at then return jsonb_build_object('acted',false,'due_in',extract(epoch from a.hammer_at-now())); end if;

  select * into l from lots where id=a.current_lot for update;
  select * into top from bids where lot_id=l.id order by amount desc, created_at asc limit 1;
  sold := top.id is not null and (l.reserve_pence is null or top.amount >= l.reserve_pence);

  if sold then
    update lots set status='sold', winner_id=top.bidder_id, winning_bid=top.id,
                    payment_deadline = now() + make_interval(hours =>
                      coalesce((select (value)::int from settings where key='payment_window_hours'),72))
     where id=l.id;
  else
    update lots set status='unsold' where id=l.id;   -- reserve negotiation attaches here later
  end if;

  select * into nxt from lots
   where auction_id=p_auction and status='listed'
   order by run_order limit 1;

  if nxt.id is not null then
    update auctions
       set current_lot=nxt.id,
           hammer_at = now() + make_interval(secs => lot_timer_secs(nxt.featured) + 5)
     where id=p_auction;
  else
    update auctions set status='closed', current_lot=null, hammer_at=null where id=p_auction;
    -- release the £50 holds of everyone who won nothing (stub; Stripe cancel in phase 3)
    update auction_entries set deposit_status='released_stub'
     where auction_id=p_auction
       and user_id not in (select winner_id from lots where auction_id=p_auction and winner_id is not null);
  end if;

  return jsonb_build_object('acted',true,'lot',l.id,'sold',sold,
    'price', coalesce(top.amount,0), 'next', nxt.id);
end $$;

-- ---------- cron backstop: never let a live auction stall ----------
create or replace function public.hammer_overdue() returns void
language plpgsql security definer set search_path=public as $$
declare a record; r jsonb; n int;
begin
  for a in select id from auctions where status='live' and hammer_at is not null and hammer_at<=now() loop
    n := 0;
    loop
      r := public.hammer_current(a.id);
      n := n + 1;
      exit when not (r->>'acted')::boolean or n >= 100;
    end loop;
  end loop;
end $$;
revoke execute on function public.hammer_overdue() from public, anon, authenticated;

-- ---------- the room's single read: everything a browser needs, in one call ----------
create or replace function public.live_state() returns jsonb
language plpgsql stable security definer set search_path=public as $$
declare a auctions%rowtype; cur jsonb; queue jsonb; results jsonb; topb record;
begin
  select * into a from auctions where status in ('scheduled','live')
   order by (status='live') desc, starts_at asc limit 1;
  if not found then
    select * into a from auctions where status='closed' order by starts_at desc limit 1;
    if not found then return jsonb_build_object('none',true); end if;
  end if;

  if a.current_lot is not null then
    select * into topb from bids where lot_id=a.current_lot order by amount desc limit 1;
    select jsonb_build_object(
      'id',l.id,'lot_no',lpad(l.lot_no::text,4,'0'),'make',l.make,'model',l.model,'year',l.year,
      'mileage',l.mileage,'cat',l.cat,'featured',l.featured,'location',l.location,
      'reg',case when is_verified(auth.uid()) then l.reg else '' end,
      'current_pence', coalesce(topb.amount, l.start_pence),
      'has_bids', topb.id is not null,
      'min_next_pence', case when topb.id is null then greatest(l.start_pence,15000)
                             else topb.amount + bid_increment(topb.amount) end,
      'bid_count',(select count(*) from bids where lot_id=l.id),
      'reserve_met', l.reserve_pence is null or coalesce(topb.amount,0) >= l.reserve_pence,
      'has_reserve', l.reserve_pence is not null,
      'timer_secs', lot_timer_secs(l.featured),
      'i_lead', topb.bidder_id = auth.uid(),
      'is_mine', l.seller_id = auth.uid()
    ) into cur from lots l where l.id=a.current_lot;
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'id',id,'lot_no',lpad(lot_no::text,4,'0'),'make',make,'model',model,'year',year,
           'featured',featured,'start_pence',start_pence) order by run_order),'[]')
    into queue
    from lots where auction_id=a.id and status='listed' and id is distinct from a.current_lot;

  select coalesce(jsonb_agg(jsonb_build_object(
           'lot_no',lpad(l.lot_no::text,4,'0'),'make',l.make,'model',l.model,
           'sold',l.status='sold',
           'price',(select max(amount) from bids where lot_id=l.id)) order by l.run_order),'[]')
    into results
    from lots l where l.auction_id=a.id and l.status in ('sold','unsold') and l.run_order is not null;

  return jsonb_build_object(
    'auction_id',a.id,'status',a.status,'skipped',a.skipped,
    'starts_at',a.starts_at,'hammer_at',a.hammer_at,'server_now',now(),
    'current',cur,'queue',queue,'results',results);
end $$;

-- ---------- upcoming auctions (for the sell page's week picker) ----------
create or replace function public.upcoming_auctions()
returns table (id uuid, title text, starts_at timestamptz, skipped boolean)
language sql stable security definer set search_path=public as $$
  select id, title, starts_at, skipped from auctions
   where status='scheduled' order by starts_at limit 6;
$$;

-- ---------- realtime + visibility: let browsers hear bids and auction changes ----------
create policy "bids on visible lots readable" on public.bids for select
  using (exists (select 1 from public.lots l where l.id=lot_id and l.status in ('listed','sold','unsold')));
grant select on public.bids to anon, authenticated;

-- fill the calendar now
select public.schedule_next_auctions();

-- ============================================================================
--  AFTER RUNNING THIS FILE, two one-time dashboard steps:
--
--  1. Database -> Publications -> supabase_realtime -> also enable the
--     AUCTIONS table (bids is already on).
--
--  2. Database -> Extensions -> enable "pg_cron", then run:
--       select cron.schedule('amc-engine','* * * * *', $cron$
--         select public.auction_autostart();
--         select public.hammer_overdue();
--         select public.schedule_next_auctions();
--       $cron$);
--     That minute-tick auto-starts Saturday auctions, advances any stalled
--     live auction, and keeps the next 4 Saturdays on the calendar.
-- ============================================================================
