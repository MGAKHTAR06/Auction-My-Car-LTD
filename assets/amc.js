/* ============================================================
   AUCTION MY CAR — shared app layer
   Real fee schedule (from Bidding_fee.ods) · mock lot data ·
   engine rules · nav/footer injection · safe state storage.
   In production this file's DATA + engine calls become API
   calls to the Next.js backend; the pages stay the same.
   ============================================================ */

/* ---------- THE REAL FEE SCHEDULE (buyer's auction fee) ---------- */
const FEE_BANDS = [
  [0.01,49.99,{flat:5}],[50,99.99,{flat:20}],[100,199.99,{flat:45}],[200,299.99,{flat:65}],
  [300,349.99,{flat:75}],[350,399.99,{flat:85}],[400,449.99,{flat:95}],[450,499.99,{flat:100}],
  [500,549.99,{flat:105}],[550,599.99,{flat:115}],[600,699.99,{flat:125}],[700,799.99,{flat:140}],
  [800,899.99,{flat:155}],[900,999.99,{flat:170}],[1000,1199.99,{flat:185}],[1200,1299.99,{flat:205}],
  [1300,1399.99,{flat:215}],[1400,1499.99,{flat:225}],[1500,1599.99,{flat:235}],[1600,1699.99,{flat:245}],
  [1700,1799.99,{flat:260}],[1800,1999.99,{flat:270}],[2000,2399.99,{flat:300}],[2400,2499.99,{flat:325}],
  [2500,2999.99,{flat:350}],[3000,3499.99,{flat:385}],[3500,3999.99,{flat:425}],[4000,4499.99,{flat:470}],
  [4500,4999.99,{flat:495}],[5000,5999.99,{flat:515}],[6000,7499.99,{flat:525}],[7500,9999.99,{flat:550}],
  [10000,10000000,{pct:0.055}]
];
function auctionFee(price){
  for(const [lo,hi,f] of FEE_BANDS){ if(price>=lo && price<=hi) return f.flat!=null ? f.flat : +(price*f.pct).toFixed(2); }
  return 0;
}
function processingFee(total){ return +(total*0.015+0.20).toFixed(2); } // Stripe UK pass-through
const DEPOSIT=50, LISTING_FEE=25, FEATURED_FEE=10, VERIFY_FEE=5, MIN_BID=150;
function increment(price){ return price<1000?50 : price<5000?100 : 200; }
function timerFor(lot){ return lot.featured?30:15; } // soft-close seconds

/* ---------- MOCK LOTS (become API data later) ---------- */
const CAR_SVG='<svg viewBox="0 0 200 110" fill="none"><path d="M18 78l10-30c2-6 7-10 14-10h66c6 0 11 3 14 8l16 22 26 6c5 1 8 5 8 10v8c0 3-2 5-5 5h-14" stroke="#5b6b86" stroke-width="3.4" stroke-linejoin="round" stroke-linecap="round"/><path d="M18 78h150" stroke="#5b6b86" stroke-width="3.4" stroke-linecap="round"/><path d="M52 38l-7 20h60l-12-20H52z" stroke="#5b6b86" stroke-width="3"/><circle cx="58" cy="80" r="13" fill="#fff" stroke="#5b6b86" stroke-width="3.4"/><circle cx="135" cy="80" r="13" fill="#fff" stroke="#5b6b86" stroke-width="3.4"/></svg>';

const LOTS=[];   // live database is the only source of cars now
const CATNAME={clean:'Clean',n:'Cat N',s:'Cat S'};

/* ---------- auction dates ---------- */
function auctionDateFor(week){ const d=nextAuction(); d.setDate(d.getDate()+7*(week||0)); return d; }
function shortDate(d){ return d.toLocaleDateString('en-GB',{day:'numeric',month:'short'}); }

/* ---------- next auction: Saturday 8:00 AM ---------- */
function nextAuction(){
  const d=new Date(),t=new Date(d);
  const diff=(6-d.getDay()+7)%7; t.setDate(d.getDate()+diff); t.setHours(8,0,0,0);
  if(t<=d) t.setDate(t.getDate()+7);
  return t;
}

/* ---------- safe state (works deployed; falls back in-memory) ---------- */
const _mem={};
const S={
  get(k){ try{return localStorage.getItem('amc_'+k)}catch(e){return _mem[k]??null} },
  set(k,v){ try{localStorage.setItem('amc_'+k,v)}catch(e){_mem[k]=v} },
  del(k){ try{localStorage.removeItem('amc_'+k)}catch(e){delete _mem[k]} }
};
async function amcLogout(){
  try{ if(window.API) await window.API.logout(); }catch(e){}
  AUTH.logout(); S.del('verified'); S.del('entered'); S.del('consentAt');
  location.href='index.html';
}
const AUTH={
  get user(){ const u=S.get('user'); return u?JSON.parse(u):null; },
  login(name,email){ S.set('user',JSON.stringify({name,email,verified:S.get('verified')==='1'})); },
  logout(){ S.del('user'); },
  get verified(){ return S.get('verified')==='1'; },
  verify(){ S.set('verified','1'); const u=this.user; if(u){u.verified=true;S.set('user',JSON.stringify(u));} },
  get entered(){ return S.get('entered')==='1'; },   // £50 deposit + consents for this auction
  enter(){ S.set('entered','1'); S.set('consentAt',new Date().toISOString()); }
};

/* ---------- shared UI ---------- */
function fmt(n){ return '£'+Number(n).toLocaleString('en-GB',{minimumFractionDigits:(n%1?2:0)}); }
function plate(reg,blur){ return `<span class="plate ${blur?'blur':''}"><span class="gb">UK</span><span class="num">${reg}</span></span>`; }
function catBadge(c){ return `<span class="badge cat ${c}">${CATNAME[c]}</span>`; }
function toast(msg,kind){ let box=document.querySelector('.toasts'); if(!box){box=document.createElement('div');box.className='toasts';document.body.appendChild(box);}
  const t=document.createElement('div'); t.className='toast '+(kind||''); t.textContent=msg; box.appendChild(t);
  setTimeout(()=>t.remove(),2800); }

function lotCard(l){
  const v=AUTH.verified;
  return `<article class="card" onclick="location.href='lot.html?lot=${l.id}'">
    <div class="ph">${CAR_SVG}<span class="badge lotno">LOT ${l.no||l.id}</span>${catBadge(l.cat)}${l.featured?'<span class="badge feat">★ Featured</span>':''}</div>
    <div class="cb">
      <div class="nm">${l.year} ${l.make} ${l.model}</div>
      <div class="meta">${plate(l.reg,!v)}<span>· ${l.miles.toLocaleString()} mi</span><span>· ${l.fuel}</span></div>
      <div class="pr">
        <div><div class="l">Current bid</div><div class="v mono">${fmt(l.cur)}</div></div>
        <div class="chip ${l.week===0?'':'soon'}" title="Auction date">${shortDate(auctionDateFor(l.week))} · 8AM</div>
      </div>
    </div>
  </article>`;
}

function navHTML(active){
  const u=AUTH.user;
  return `<div class="wrap nav">
    <a class="brand" href="index.html"><img src="assets/logo.png" alt="Auction My Car logo" style="height:36px;width:auto" onerror="this.style.display='none';this.nextElementSibling.style.display='grid'"><span class="mark" style="display:none"><svg viewBox="0 0 24 24" fill="none"><path d="M3 13l2-5a3 3 0 012.8-2h8.4A3 3 0 0119 8l2 5v5a1 1 0 01-1 1h-2a1 1 0 01-1-1v-1H7v1a1 1 0 01-1 1H4a1 1 0 01-1-1v-5z" stroke="#fff" stroke-width="1.7" stroke-linejoin="round"/><circle cx="7.5" cy="14.5" r="1.2" fill="#fff"/><circle cx="16.5" cy="14.5" r="1.2" fill="#fff"/></svg></span>Auction My Car</a>
    <div class="grow"></div>
    <nav class="navlinks">
      <a href="browse.html" class="${active==='browse'?'on':''}">Browse auction</a>
      <a href="live.html" class="${active==='live'?'on':''}">Live · Saturday</a>
      <a href="sell.html" class="${active==='sell'?'on':''}">Sell your car</a>
      <a href="help.html" class="${active==='help'?'on':''}">Help</a>
    </nav>
    ${u?`<button class="pill ${AUTH.verified?'ok':''}" onclick="location.href='login.html'"><span class="dot"></span>${AUTH.verified?'Verified':'Not verified'}</button>
         <a class="btn ghost sm" href="dashboard.html">${u.name.split(' ')[0]}</a>
         <button class="btn ghost sm" onclick="amcLogout()" title="Log out">Log out</button>`
       :`<a class="btn ghost sm" href="login.html">Log in</a><a class="btn sm" href="login.html?tab=register">Join free</a>`}
  </div>`;
}
function footHTML(){
  return `<div class="wrap foot">
    <span>© ${new Date().getFullYear()} Auction My Car · Peer-to-peer vehicle auctions, UK</span>
    <div class="links"><a href="about.html">About</a><a href="help.html">Help</a><a href="contact.html">Contact</a><a href="terms.html">Terms &amp; Privacy</a></div>
    <span class="plate"><span class="gb">UK</span><span class="num">AMC 1</span></span>
  </div>`;
}
function renderNav(){
  const h=document.querySelector('header.site'); if(h) h.innerHTML=navHTML(h.dataset.page||'');
}
window.renderNav=renderNav;
document.addEventListener('DOMContentLoaded',()=>{
  renderNav();
  const f=document.querySelector('footer.site'); if(f) f.innerHTML=footHTML();
});

/* countdown chips + digit clocks */
function pad(n){return String(n).padStart(2,'0')}
function startClocks(){
  const T=nextAuction();
  const when=document.querySelectorAll('[data-when]');
  when.forEach(el=>el.textContent=T.toLocaleDateString('en-GB',{weekday:'long',day:'numeric',month:'long'})+' · 8:00 AM');
  setInterval(()=>{
    let ms=T-Date.now(); if(ms<0)ms=0; const s=Math.floor(ms/1000);
    const set=(id,v)=>{const e=document.getElementById(id); if(e)e.textContent=v;};
    set('cd-d',Math.floor(s/86400)); set('cd-h',pad(Math.floor(s%86400/3600)));
    set('cd-m',pad(Math.floor(s%3600/60))); set('cd-s',pad(s%60));
  },1000);
}
