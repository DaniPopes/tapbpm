import { defineConfig } from "vite";

export default defineConfig({
  base: "./",
  define: { __BUILD__: JSON.stringify(Date.now().toString(36)) },
  build: { target: "es2022" },
  worker: { format: "es" },
  optimizeDeps: { exclude: ["onnxruntime-web"] },
});
