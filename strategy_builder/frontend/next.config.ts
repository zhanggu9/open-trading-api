import type { NextConfig } from "next";

// localhost는 환경에 따라 IPv6(::1)로 풀려 127.0.0.1에만 바인딩된 백엔드에 닿지 않을 수 있다.
const backendUrl = (process.env.BACKEND_URL || "http://127.0.0.1:8000").replace(/\/$/, "");

const nextConfig: NextConfig = {
  // P1: Frontend 3000, Backend 8000. Set BACKEND_URL to override the local default.
  async rewrites() {
    return [
      {
        source: '/api/:path*',
        destination: `${backendUrl}/api/:path*`,
      },
    ];
  },
};

export default nextConfig;
