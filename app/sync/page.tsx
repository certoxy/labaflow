"use client";
import {useEffect,useState} from "react";
import {jobs,syncHistory,type OfflineJob,type SyncHistory} from "../../lib/offlineQueue";
import {currentOfflineScope} from "../../lib/offlineScope";

const names:Record<string,string>={create_order:"New Order",update_order_status:"Order Status",record_cash_payment:"Cash Payment",create_customer:"New Customer"};

export default function SyncPage(){
  const [pending,setPending]=useState<OfflineJob[]>([]),[history,setHistory]=useState<SyncHistory[]>([]),[online,setOnline]=useState(true);
  async function load(){const scope=await currentOfflineScope();if(!scope){setPending([]);setHistory([]);return}setPending(await jobs(scope));setHistory(await syncHistory(scope))}
  useEffect(()=>{setOnline(navigator.onLine);load();const fn=()=>load(),on=()=>{setOnline(true);load()},off=()=>setOnline(false);window.addEventListener("labaflow:queue-changed",fn);window.addEventListener("labaflow:offline-synced",fn);window.addEventListener("online",on);window.addEventListener("offline",off);return()=>{window.removeEventListener("labaflow:queue-changed",fn);window.removeEventListener("labaflow:offline-synced",fn);window.removeEventListener("online",on);window.removeEventListener("offline",off)}},[]);
  const failed=pending.filter(x=>x.status==="failed").length;
  return <main className="workspace syncPage">
    <header className="syncHeader"><div><p className="eyebrow">OFFLINE RESILIENCE</p><h1>Sync Center</h1><p className="muted">Offline activity for the current organization. Changes sync automatically when connection returns.</p></div><div className="syncConnection" title={online?"Online":"Offline"}><span className={`syncDot ${online?"online":""}`}/><span>{online?"Online":"Offline"}</span></div></header>
    <section className="syncStats">
      <article className="syncStat connection"><span>Connection</span><strong>{online?"Online":"Offline"}</strong></article>
      <article className="syncStat"><span>Pending</span><strong>{pending.length}</strong></article>
      <article className="syncStat"><span>Failed</span><strong>{failed}</strong></article>
      <article className="syncStat"><span>Synced</span><strong>{history.length}</strong></article>
    </section>
    <div className="syncSections">
      <section className="panel syncPanel"><div className="panelHead"><div><h2>Pending Changes</h2><span>Waiting to synchronize with LabaFlow.</span></div></div>{pending.length?pending.map(j=><article className="orderCard" key={j.id}><div className="orderTop"><div><strong>{names[j.kind]||j.kind}</strong><small>{new Date(j.createdAt).toLocaleString()} · {j.id.slice(0,8)}</small></div><span className={`status ${j.status}`}>{j.status}</span></div>{j.error&&<p className="notice">Sync error: {j.error}</p>}</article>):<div className="syncEmpty"><span className="syncEmptyIcon">✓</span><span>Everything is synced. No pending changes.</span></div>}</section>
      <section className="panel syncPanel"><div className="panelHead"><div><h2>Recent Sync History</h2><span>Latest successful offline transactions.</span></div></div>{history.length?history.map(h=><article className="orderCard" key={h.id}><div className="orderTop"><div><strong>✓ {names[h.kind]||h.kind}</strong><small>{new Date(h.syncedAt).toLocaleString()} · {h.id.slice(0,8)}</small></div><span className="status active">Synced</span></div></article>):<div className="syncEmpty"><span className="syncEmptyIcon">↻</span><span>No offline transactions have been synced yet.</span></div>}</section>
    </div>
  </main>
}
