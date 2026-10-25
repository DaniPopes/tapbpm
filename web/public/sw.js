// Serves the app from the cache, so it starts instantly and works offline. Assets and the model
// have content-hashed names; the page itself is refreshed in the background for the next launch.
const CACHE = "tapbpm-v1";

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
      const cached = await cache.match(request);
      if (cached && request.mode !== "navigate") return cached;
      const fetched = fetch(request).then((response) => {
        if (response.ok) event.waitUntil(cache.put(request, response.clone()));
        return response;
      });
      if (!cached) return fetched;
      event.waitUntil(fetched.catch(() => {}));
      return cached;
    })(),
  );
});
