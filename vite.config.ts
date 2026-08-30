import vinext from "vinext";
import { nitro } from "nitro/vite";
import { defineConfig } from "vite";

const useNitro = Boolean(process.env.VERCEL || process.env.NITRO_PRESET);

export default defineConfig({
  server: {
    host: "0.0.0.0",
  },
  plugins: [
    vinext(),
    ...(useNitro ? [nitro()] : []),
  ],
});
