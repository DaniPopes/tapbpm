// Caches the app for offline use and instant starts. Each build registers this worker with its
// own version, so a deploy installs a new worker with a fresh cache and drops the old one.
const CACHE = `tapbpm-${new URL(location.href).searchParams.get("v")}`;

self.addEventListener("install", () => self.skipWaiting());

self.addEventListener("activate", (event) => {
  event.waitUntil(
    (async () => {
      for (const key of await caches.keys()) if (key !== CACHE) await caches.delete(key);
      await self.clients.claim();
    })(),
  );
});

self.addEventListener("fetch", (event) => {
  const request = event.request;
  if (request.method !== "GET" || new URL(request.url).origin !== location.origin) return;
  event.respondWith(
    (async () => {
      const cache = await caches.open(CACHE);
      // Pages come from the network so updates show at once; assets have content-hashed names.
      if (request.mode !== "navigate") {
        const cached = await cache.match(request);
        if (cached) return cached;
      }
      try {
        const response = await fetch(request);
        if (response.ok) event.waitUntil(cache.put(request, response.clone()));
        return response;
      } catch (error) {
        const cached = await cache.match(request);
        if (cached) return cached;
        throw error;
      }
    })(),
  );
});
