# Auction My Car 🚗

A UK **peer-to-peer live car auction platform** — sellers list their vehicles and buyers compete in a **timed live auction every Saturday**, with identity verification, deposit holds and payments handled through Stripe. The bidding rules run **server-side inside PostgreSQL**, so the auction can't be manipulated from the browser.

This repository tracks the project's development **version by version**, from the first static prototype through to the current database-backed build.

![PostgreSQL](https://img.shields.io/badge/PostgreSQL-4169E1?style=flat&logo=postgresql&logoColor=white)
![Supabase](https://img.shields.io/badge/Supabase-3ECF8E?style=flat&logo=supabase&logoColor=white)
![Stripe](https://img.shields.io/badge/Stripe-635BFF?style=flat&logo=stripe&logoColor=white)
![JavaScript](https://img.shields.io/badge/JavaScript-F7DF1E?style=flat&logo=javascript&logoColor=black)
![HTML5](https://img.shields.io/badge/HTML5-E34F26?style=flat&logo=html5&logoColor=white)

---

## 📋 Overview

Rather than rolling listings, Auction My Car runs a **single timed live auction each week**. Sellers submit a car through a multi-step listing form (damage declaration, V5C + VIN), it's approved, then it goes into the next Saturday sale. Buyers verify their identity, place pre-bids, and compete in a live room with a soft-close timer. Winners pay through a real fee schedule, with a deposit hold and a 72-hour completion clock.

The front end is a **static site** (no build step); all the heavy lifting — accounts, listings, bidding rules, security — is done by **Supabase (PostgreSQL)**.


## 🏗️ Architecture (current build)

- **Front end** — static HTML/CSS/JS, one shared design system across ~14 pages (home, browse, lot, live room, sell, buyer/seller dashboards, checkout, hidden admin panel, plus help/about/contact/terms).
- **Database** — Supabase / PostgreSQL holds accounts, listings, bids, auctions and payments.
- **Security** — **Row-Level Security (RLS) is deny-by-default** on every table; the only way in is through SQL functions that re-check identity and rules on every call.
- **Bidding engine** — `place_bid()` enforces increments, the self-bid block and the verified-only gate **inside the database with a row lock**, so two people bidding at once can't corrupt the price.
- **Payments** — Stripe **Edge Functions** (Deno) handle listing-fee payments and webhooks; Stripe Connect is planned for held funds and payout splits.

## ⚙️ Engineering Highlights

- **Server-authoritative auctions** — the rules live in Postgres, not the page, so the client can't be trusted or tricked.
- **Defence-in-depth** — RLS means even a leaked publishable key exposes nothing; data is only reachable through vetted functions.
- **Soft-close live room** — sequential lots with a 15s/30s soft-close timer to stop last-second sniping.
- **Real fee schedule** — a 33-band fee table baked into checkout.
- **Verified gating enforced by the DB** — VIN/registration are hidden from unverified visitors at the data layer, not just the UI.

## 🛠️ Tech Stack

| Layer | Technology |
| ----- | ---------- |
| Front end | HTML5 · CSS3 · vanilla JavaScript |
| Database | Supabase (PostgreSQL) with RLS + SQL functions |
| Server logic | Supabase Edge Functions (Deno / TypeScript) |
| Payments | Stripe (Connect planned) |
| Hosting | Static host (Fasthosts / Netlify / Vercel / Cloudflare Pages) |

## 🚀 Running a Version

Each version is a static site:

```bash
# from a version folder, e.g.
cd 13-amc-current
npx serve .        # or just open index.html
```

For the database-backed versions, follow that folder's `PHASE1-SETUP.md` to create the Supabase schema and connect it. You'll need to add your own Supabase project URL and publishable key (see below).

## 🔐 Security & Configuration

**No secret keys are committed to this repo.** Before publishing, the following were done to keep it safe for a public repository:

- The real **Supabase project URL** and **publishable key** in `assets/api.js` were replaced with placeholders (`YOUR_PROJECT_ID`, `YOUR_SUPABASE_PUBLISHABLE_KEY`). Add your own to run it. The publishable key is safe to expose by design — every table is deny-by-default and protected by RLS.
- The Stripe **secret key** and Supabase **service-role key** are never in the front end. The Edge Functions read them from environment variables (`Deno.env.get(...)`) and must be set as Supabase function secrets, never committed.

> ⚠️ **Rotate the Stripe secret key** (Stripe Dashboard → Developers → API keys) if it was ever shared outside your own environment, before going live.

## 📂 Repository Structure

```
auction-my-car/
├── README.md              # this file
├── .gitignore
├── 00-initial-static-prototype/
├── 01-phase-1.1-failed/
├── ...
├── 12-phase-2.3/
└── 13-amc-current/
    ├── *.html
    ├── assets/            # amc.css, amc.js, api.js, logo
    ├── supabase/          # schema.sql, phase2/3.sql, functions/
    ├── README.md
    └── PHASE1-SETUP.md
```

## 👤 Author

Designed and built by **Musab** — [LinkedIn](https://www.linkedin.com/in/musab-akhtar/) 
