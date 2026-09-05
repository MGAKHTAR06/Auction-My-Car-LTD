-- ============================================================================
--  AUCTION MY CAR — ADMIN PANEL BACKEND
--  Run ONCE in Supabase SQL Editor (phase 1 + 2 must already exist).
--  Every function re-checks the caller's role inside the database, so the
--  admin page is just a window — the authority lives here.
-- ============================================================================

-- ---------- overview numbers ----------
create or replace function public.admin_stats() returns jsonb
language plpgsql stable security definer set search_path=public as $$
declare nxt record;
begin
  if not is_admin(auth.uid()) then raise exception 'Admins only'; end if;
  select * into nxt from auctions where status in ('scheduled','live')
   order by (status='live') desc, starts_at limit 1;
  return jsonb_build_object(
    'members',        (select count(*) from profiles),
    'verified',       (select count(*) from profiles where verified),
    'pending',        (select count(*) from lots where status='pending'),
    'listed',         (select count(*) from lots where status='listed'),
    'sold',           (select count(*) from lots where status='sold'),
    'unsold',         (select count(*) from lots where status='unsold'),
    'next_auction',   case when nxt.id is null then null else jsonb_build_object(
                        'id',nxt.id,'starts_at',nxt.starts_at,'status',nxt.status,
                        'skipped',nxt.skipped,
                        'entries',(select count(*) from auction_entries where auction_id=nxt.id),
                        'lots',(select count(*) from lots where auction_id=nxt.id and status='listed')) end);
end $$;

-- ---------- the approval queue, with everything a reviewer must see ----------
create or replace function public.admin_pending_lots()
returns table (id uuid, lot_no int, created_at timestamptz, make text, model text, year int,
               mileage int, reg text, vin text, cat title_cat, fuel text, transmission text,
               engine text, owners int, mot text, location text, description text, damage text,
               start_pence int, reserve_pence int, buy_now_pence int, featured boolean,
               seller_name text, auction_starts timestamptz)
language plpgsql stable security definer set search_path=public as $$
begin
  if not is_admin(auth.uid()) then raise exception 'Admins only'; end if;
  return query
  select l.id, l.lot_no, l.created_at, l.make, l.model, l.year, l.mileage, l.reg, l.vin,
         l.cat, l.fuel, l.transmission, l.engine, l.owners, l.mot, l.location,
         l.description, l.damage, l.start_pence, l.reserve_pence, l.buy_now_pence,
         l.featured, p.name, a.starts_at
    from lots l
    join profiles p on p.id = l.seller_id
    join auctions a on a.id = l.auction_id
   where l.status = 'pending'
   order by l.created_at;
end $$;

-- ---------- recent outcomes: what sold, for how much, paid or not ----------
create or replace function public.admin_recent_lots()
returns table (id uuid, lot_no int, make text, model text, status lot_status,
               top_pence bigint, payment_deadline timestamptz, seller_name text)
language plpgsql stable security definer set search_path=public as $$
begin
  if not is_admin(auth.uid()) then raise exception 'Admins only'; end if;
  return query
  select l.id, l.lot_no, l.make, l.model, l.status,
         (select max(amount) from bids b where b.lot_id=l.id)::bigint,
         l.payment_deadline, p.name
    from lots l join profiles p on p.id=l.seller_id
   where l.status in ('sold','unsold','rejected','defaulted')
   order by coalesce(l.payment_deadline, l.created_at) desc
   limit 25;
end $$;

-- ---------- members (master admin only) ----------
create or replace function public.admin_users()
returns table (id uuid, email text, name text, verified boolean,
               is_admin boolean, is_master boolean, created_at timestamptz)
language plpgsql stable security definer set search_path=public as $$
begin
  if not exists (select 1 from profiles where profiles.id=auth.uid() and profiles.is_master)
    then raise exception 'Master admin only'; end if;
  return query
  select p.id, u.email::text, p.name, p.verified, p.is_admin, p.is_master, p.created_at
    from profiles p join auth.users u on u.id=p.id
   order by p.created_at desc;
end $$;

-- ---------- settings editor (master admin only) ----------
create or replace function public.admin_set_setting(p_key text, p_value jsonb) returns void
language plpgsql security definer set search_path=public as $$
begin
  if not exists (select 1 from profiles where id=auth.uid() and is_master)
    then raise exception 'Master admin only'; end if;
  insert into settings (key, value) values (p_key, p_value)
  on conflict (key) do update set value = excluded.value;
end $$;
