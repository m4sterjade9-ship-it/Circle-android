/* Circle service worker v46: instant opens. App shell = show saved copy now, refresh in background.
   The Supabase library is cached too, so repeat visits skip that download. Data always comes live from Supabase. */
const V='circle-v49',LIB='https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.58.0/dist/umd/supabase.min.js',SHELL=['./','index.html','manifest.webmanifest','icon.svg','icon-192.png','icon-512.png'];
self.addEventListener('install',e=>{e.waitUntil(caches.open(V).then(c=>Promise.all([c.addAll(SHELL),fetch(LIB).then(r=>r.ok&&c.put(LIB,r)).catch(()=>{})])).then(()=>self.skipWaiting()))});
self.addEventListener('activate',e=>{e.waitUntil(caches.keys().then(k=>Promise.all(k.filter(x=>x!==V).map(x=>caches.delete(x)))).then(()=>self.clients.claim()))});
self.addEventListener('fetch',e=>{
  const r=e.request,u=new URL(r.url);
  if(r.method!=='GET')return;
  if(r.url===LIB){e.respondWith(caches.match(r).then(m=>m||fetch(r).then(res=>{if(res.ok){const cp=res.clone();caches.open(V).then(c=>c.put(r,cp))}return res})));return}
  if(u.origin!==location.origin)return; // never touch Supabase data, fonts or uploads
  e.respondWith(caches.open(V).then(c=>c.match(r).then(m=>{
    const net=fetch(r).then(res=>{if(res.ok)c.put(r,res.clone());return res}).catch(()=>m||c.match('index.html'));
    return m||net})));
});

self.addEventListener('notificationclick',e=>{e.notification.close();e.waitUntil(self.clients.matchAll({type:'window',includeUncontrolled:true}).then(l=>{for(const c of l){if('focus' in c)return c.focus()}return self.clients.openWindow('./')}))});
