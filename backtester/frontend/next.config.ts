import type { NextConfig } from "next";

const backendUrl = (process.env.BACKEND_URL || "http://127.0.0.1:8002").replace(/\/$/, "");

const nextConfig: NextConfig = {
  // Frontend 3001 → Backend 8002. Set BACKEND_URL to override the local default.
  async rewrites() {
    return [
      {
        source: "/api/:path*",
        destination: `${backendUrl}/api/:path*`,
      },
    ];
  },
};

export default nextConfig;
