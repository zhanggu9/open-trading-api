import type { NextConfig } from "next";

const backendUrl = (process.env.BACKEND_URL || "http://127.0.0.1:8002").replace(/\/$/, "");
// 단일 포트 배포(deploy/)에서는 전략 빌더와 같은 origin을 공유하므로 /_next, /api 경로가 겹치지 않게
// 정적 자원(ASSET_PREFIX)과 API 호출(NEXT_PUBLIC_API_URL)에 이 앱 전용 prefix를 붙인다. 로컬 개발에서는 비워 둔다.
const assetPrefix = (process.env.ASSET_PREFIX || "").replace(/\/$/, "");
const apiPrefix = (process.env.NEXT_PUBLIC_API_URL || "").replace(/\/$/, "");

const nextConfig: NextConfig = {
  ...(assetPrefix ? { assetPrefix } : {}),
  // Frontend 3001 → Backend 8002. Set BACKEND_URL to override the local default.
  async rewrites() {
    const rules = [
      {
        source: "/api/:path*",
        destination: `${backendUrl}/api/:path*`,
      },
    ];
    // API prefix가 상대 경로(/backtest 등)면 리버스 프록시 없이 3001에 직접 붙어도 API가 동작하게 한다.
    if (apiPrefix.startsWith("/")) {
      rules.push({
        source: `${apiPrefix}/api/:path*`,
        destination: `${backendUrl}/api/:path*`,
      });
    }
    return rules;
  },
};

export default nextConfig;
