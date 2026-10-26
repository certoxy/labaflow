import type { MetadataRoute } from "next";

const siteUrl = "https://labaflow.paotechs.com";

export default function robots(): MetadataRoute.Robots {
  return {
    rules: {
      userAgent: "*",
      allow: ["/", "/privacy", "/account-deletion"],
      disallow: [
        "/admin/",
        "/api/",
        "/customer/",
        "/customers/",
        "/dashboard/",
        "/join/",
        "/loyalty/",
        "/new-order/",
        "/order-details/",
        "/orders/",
        "/organization/",
        "/pickup-delivery/",
        "/products/",
        "/receipt/",
        "/reports/",
        "/services/",
        "/staff-login/",
        "/sync/",
      ],
    },
    sitemap: `${siteUrl}/sitemap.xml`,
    host: siteUrl,
  };
}
