// Flip detection. Runs in the browser on data/latest.json.
//
//   reset     - buy listings far below the item's normal price, relist at normal price
//   arbitrage - buy in one auction house, sell in another (Alliance / Horde / Blackwater)
//   vendor    - buy listings priced below what a vendor pays, sell to vendor (no risk)
//
// All prices are copper per unit. 1 g = 100 s = 10 000 c.
// Filters (f) use copper for min_profit and fractions for min_roi / buy_pct.

const FACTION_CUT = 0.05;   // AH cut on Alliance/Horde houses
const NEUTRAL_CUT = 0.15;   // AH cut on the neutral (Blackwater) house
const MIN_TRACKED_H = 12;   // hours of sales tracking before sells/day is trusted

function prepare(raw) {
  const D = { status: raw.status, items: raw.items, houses: new Map(), ladders: new Map(), markets: new Map(), list: [],
              recipes: raw.recipes || [] };
  for (const [id, name, neutral] of raw.houses) D.houses.set(id, { id, name, neutral: !!neutral });
  for (const [h, i, lad] of raw.ladders) { D.ladders.set(h + ":" + i, lad); D.list.push([h, i, lad]); }
  for (const [h, i, market, seen, avg_listings, avg_quantity, sold_per_day, tracked_h, sell_rate, low7, avg7, high7, chg24, chg7] of raw.markets)
    D.markets.set(h + ":" + i, { market, seen, avg_listings, avg_quantity, sold_per_day, tracked_h, sell_rate, low7, avg7, high7, chg24, chg7 });
  D.region = raw.region || {};
  return D;
}

// Can a character of this faction use this house? (faction null = all houses)
function accessible(house, faction) {
  if (!faction || !house) return true;
  return house.neutral || (house.name || "").toLowerCase().includes(faction.toLowerCase());
}
const cutOf = (house) => (house && house.neutral ? NEUTRAL_CUT : FACTION_CUT);
const confidenceOf = (seen) => (seen >= 24 ? "high" : seen >= 6 ? "medium" : "low");
const houseName = (D, id) => (D.houses.get(id) || {}).name || String(id);

// Estimated units sold per day, or null while there isn't enough tracking.
function sellsDay(m) {
  if (m.sold_per_day == null || (m.tracked_h || 0) < MIN_TRACKED_H) return null;
  return m.sold_per_day;
}
const round1 = (v) => (v == null ? null : Math.round(v * 10) / 10);

// Most units worth buying: what the market normally holds, and what sells within sellDays.
function capOf(m, sellDays) {
  let cap = m.avg_quantity;
  const s = sellsDay(m);
  if (sellDays && s != null) cap = Math.min(cap, s * sellDays);
  return Math.max(1, Math.ceil(cap));
}

// Price of the cheapest unit left after buying the cheapest `bought` units.
function nextPrice(ladder, bought) {
  let left = bought;
  for (const [price, qty] of ladder) {
    if (left < qty) return price;
    left -= qty;
  }
  return null;
}

// Walk the price ladder cheapest-first.
function buyLadder(ladder, maxPrice, maxUnits) {
  let units = 0, cost = 0, n = 0, top = 0;
  for (const [price, qty, listings] of ladder) {
    if (price > maxPrice || units >= maxUnits) break;
    const take = Math.min(qty, maxUnits - units);
    units += take;
    cost += take * price;
    n += take === qty ? listings : Math.max(1, Math.ceil(listings * take / qty));
    top = price;
  }
  return { units, cost, top, n };
}

function itemOf(D, id) {
  const it = D.items[id] || [];
  return { item_id: id, name: it[0] || `Item ${id}`, quality: it[1] || "", vendor: it[2] || 0, icon: it[3] || "", vendor_buy: it[4] || 0 };
}

function resetFlips(D, f, faction) {
  const out = [];
  for (const [hid, iid, ladder] of D.list) {
    const house = D.houses.get(hid);
    if (!accessible(house, faction)) continue;
    const m = D.markets.get(hid + ":" + iid);
    if (!m || m.seen < f.min_seen || m.avg_listings < f.min_listings) continue;
    const target = m.market, threshold = target * f.buy_pct, cut = cutOf(house), cap = capOf(m, f.sell_days);
    // We have to undercut the cheapest listing we leave behind, and buying less (because the
    // sell price dropped) can leave a cheaper one behind. Repeat until the sell price settles.
    let sell = target, b = null, settled = false;
    for (let k = 0; k < 10; k++) {
      b = buyLadder(ladder, Math.min(threshold, sell * (1 - cut) / (1 + f.min_roi)), cap);
      const nxt = nextPrice(ladder, b.units);
      const newSell = nxt != null ? Math.min(target, nxt - 1) : target;
      if (newSell >= sell) { settled = true; break; }
      sell = newSell;
    }
    if (!settled) continue; // price ladder too crowded to flip
    const net = sell * (1 - cut);
    if (!b.units || net <= 0) continue;
    const profit = b.units * net - b.cost, roi = b.cost ? profit / b.cost : 0;
    if (profit < f.min_profit || roi < f.min_roi) continue;
    out.push({
      ...itemOf(D, iid), house: houseName(D, hid), house_id: hid,
      buy_units: b.units, buy_auctions: b.n, buy_upto: b.top, cost: b.cost,
      sell_at: sell, market: target, profit, roi, seen: m.seen, avg_listings: m.avg_listings,
      sells_day: round1(sellsDay(m)), confidence: confidenceOf(m.seen),
    });
  }
  return out.sort((a, b) => b.profit - a.profit);
}

function arbitrageFlips(D, f, faction) {
  const byItem = new Map();
  for (const [hid, iid] of D.list) {
    if (!byItem.has(iid)) byItem.set(iid, []);
    byItem.get(iid).push(hid);
  }
  const out = [];
  for (const [iid, hids] of byItem) {
    if (hids.length < 2) continue;
    for (const sellH of hids) {
      const m = D.markets.get(sellH + ":" + iid);
      if (!m || m.seen < f.min_seen || m.avg_listings < f.min_listings) continue;
      const sh = D.houses.get(sellH);
      const sellLadder = D.ladders.get(sellH + ":" + iid);
      const curMin = sellLadder && sellLadder.length ? sellLadder[0][0] : null;
      const sell = curMin ? Math.min(m.market, curMin - 1) : m.market;
      const net = sell * (1 - cutOf(sh));
      const maxBuy = net / (1 + f.min_roi);
      const cap = capOf(m, f.sell_days);
      for (const buyH of hids) {
        if (buyH === sellH) continue;
        const bh = D.houses.get(buyH);
        // with a faction: both houses usable by it; "all houses": a neutral house in the route
        const own = faction ? accessible(bh, faction) && accessible(sh, faction) : !!((bh && bh.neutral) || (sh && sh.neutral));
        if (!own && !f.include_alt) continue;
        const b = buyLadder(D.ladders.get(buyH + ":" + iid), maxBuy, cap);
        if (!b.units) continue;
        const profit = b.units * net - b.cost, roi = b.cost ? profit / b.cost : 0;
        if (profit < f.min_profit || roi < f.min_roi) continue;
        out.push({
          ...itemOf(D, iid), buy_house: houseName(D, buyH), sell_house: houseName(D, sellH), house_id: sellH,
          buy_units: b.units, buy_auctions: b.n, buy_upto: b.top, cost: b.cost,
          sell_at: sell, market: m.market, profit, roi, seen: m.seen,
          route: own ? "Same character" : "Needs alt on the other faction",
          sells_day: round1(sellsDay(m)), confidence: confidenceOf(m.seen),
        });
      }
    }
  }
  return out.sort((a, b) => b.profit - a.profit);
}

function vendorFlips(D, f, faction) {
  const out = [];
  for (const [hid, iid, ladder] of D.list) {
    if (!accessible(D.houses.get(hid), faction)) continue;
    const vendor = itemOf(D, iid).vendor;
    if (vendor <= 0) continue;
    let units = 0, cost = 0, n = 0, top = 0;
    for (const [price, qty, listings] of ladder) {
      if (price >= vendor) break;
      units += qty; cost += qty * price; n += listings; top = price;
    }
    if (!units) continue;
    const profit = units * vendor - cost;
    if (profit < f.min_profit) continue;
    out.push({
      ...itemOf(D, iid), house: houseName(D, hid), house_id: hid,
      buy_units: units, buy_auctions: n, buy_upto: top, cost,
      sell_at: vendor, profit, roi: cost ? profit / cost : 0,
    });
  }
  return out.sort((a, b) => b.profit - a.profit);
}

// Cheapest place to get one unit of a reagent: a vendor (known vendor reagents only) or the
// market value in any house this character can use. -> { price, source, house_id } or null
function reagentPrice(D, iid, faction, minSeen) {
  const it = itemOf(D, iid);
  let best = it.vendor_buy ? { price: it.vendor_buy, source: "Vendor", house_id: null } : null;
  for (const h of D.houses.values()) {
    if (!accessible(h, faction)) continue;
    const m = D.markets.get(h.id + ":" + iid);
    if (!m || m.seen < minSeen) continue;
    if (!best || m.market < best.price) best = { price: m.market, source: h.name, house_id: h.id };
  }
  return best;
}

// Crafting: buy the reagents (cheapest source each), craft, sell the result at its market value
// in the best house this character can use, after the AH cut.
// f.profession filters to one profession ("" = all).
function craftFlips(D, f, faction) {
  const out = [];
  for (const [rid, recipe, profession, made, qty, reagents] of D.recipes) {
    if (f.profession && profession !== f.profession) continue;
    let sell = null;
    for (const h of D.houses.values()) {
      if (!accessible(h, faction)) continue;
      const m = D.markets.get(h.id + ":" + made);
      if (!m || m.seen < f.min_seen) continue;
      const net = m.market * (1 - cutOf(h)) * qty;
      if (!sell || net > sell.net) sell = { h, m, net };
    }
    if (!sell) continue;
    let cost = 0, missing = false;
    const parts = reagents.map(([iid, n]) => {
      const p = reagentPrice(D, iid, faction, f.min_seen);
      if (!p) missing = true; else cost += p.price * n;
      return { ...itemOf(D, iid), qty: n, price: p ? p.price : null, source: p ? p.source : null };
    });
    if (missing || cost <= 0) continue; // a reagent with no price: profit unknown
    const profit = sell.net - cost, roi = profit / cost;
    if (profit < f.min_profit || roi < f.min_roi) continue;
    out.push({
      ...itemOf(D, made), recipe_id: rid, recipe, profession, house: sell.h.name, house_id: sell.h.id,
      crafted_qty: qty, cost, sell_at: sell.m.market, profit, roi, parts, seen: sell.m.seen,
      sells_day: round1(sellsDay(sell.m)), confidence: confidenceOf(sell.m.seen),
    });
  }
  return out.sort((a, b) => b.profit - a.profit);
}

const FLIPS = { reset: resetFlips, arbitrage: arbitrageFlips, vendor: vendorFlips, craft: craftFlips };
