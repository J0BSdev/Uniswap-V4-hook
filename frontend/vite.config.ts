import { defineConfig, loadEnv } from "vite";
import react from "@vitejs/plugin-react";

export default defineConfig(({ mode }) => {
  const env = loadEnv(mode, ".", "");
  return {
    base: env.VITE_BASE_PATH || "/",
    plugins: [react()],
    server: {
      port: 5173,
      proxy: {
        "/rpc": {
          target: "http://127.0.0.1:8545",
          changeOrigin: true,
          rewrite: () => "/",
        },
      },
    },
  };
});
