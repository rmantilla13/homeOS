import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  // The console is private: never framed, never indexed, no referrer leaks.
  async headers() {
    return [
      {
        source: "/:path*",
        headers: [
          { key: "X-Frame-Options", value: "DENY" },
          { key: "X-Content-Type-Options", value: "nosniff" },
          { key: "Referrer-Policy", value: "same-origin" },
          { key: "X-Robots-Tag", value: "noindex, nofollow" },
        ],
      },
    ];
  },
  poweredByHeader: false,
};

export default nextConfig;
