import type { Config } from "tailwindcss";

const config: Config = {
  content: ["./app/**/*.{ts,tsx}", "./components/**/*.{ts,tsx}", "./lib/**/*.{ts,tsx}"],
  theme: {
    extend: {
      colors: {
        ink: "#e5eaf5",
        panel: "#151d2e",
        line: "#29344c",
        accent: "#6366f1",
        warn: "#fbbf24"
      }
    }
  },
  plugins: []
};

export default config;
