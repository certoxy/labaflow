const CACHE="labaflow-shell-v3";
const PREFIX="labaflow-shell-";
const SHELL=["/dashboard","/new-order","/orders","/customers","/pickup-delivery","/sync","/manifest.webmanifest","/labaflow-icon.svg"];

self.addEventListener("install",event=>{
  event.waitUntil(caches.open(CACHE).then(async cache=>{
    for(const path of SHELL){try{const res=await fetch(path,{cache:"reload"});if(res.ok)await cache.put(path,res.clone())}catch{}}
  }));
  self.skipWaiting();
});

self.addEventListener("activate",event=>{
  event.waitUntil(caches.keys().then(keys=>Promise.all(keys.filter(k=>k.startsWith(PREFIX)&&k!==CACHE).map(k=>caches.delete(k)))));
  self.clients.claim();
});

self.addEventListener("fetch",event=>{
  const req=event.request;
  if(req.method!=="GET")return;
  const url=new URL(req.url);
  if(url.origin!==self.location.origin)return;

  // Build assets must prefer the current deployment. Cache only successful responses.
  if(url.pathname.startsWith("/_next/")||url.pathname.startsWith("/assets/")){
    event.respondWith((async()=>{
      try{
        const res=await fetch(req,{cache:"no-store"});
        if(res.ok){const copy=res.clone();event.waitUntil(caches.open(CACHE).then(c=>c.put(req,copy)))}
        return res;
      }catch{
        const cached=await caches.match(req);
        if(cached)return cached;
        throw new Error("Asset unavailable offline");
      }
    })());
    return;
  }

  // Navigation is network-first so a new deployment never gets shadowed by stale HTML.
  if(req.mode==="navigate"){
    event.respondWith((async()=>{
      try{
        const res=await fetch(req,{cache:"no-store"});
        if(res.ok){const copy=res.clone();event.waitUntil(caches.open(CACHE).then(c=>c.put(req,copy)))}
        return res;
      }catch{
        return (await caches.match(req))||(await caches.match(url.pathname))||(await caches.match("/dashboard"))||Response.error();
      }
    })());
  }
});
