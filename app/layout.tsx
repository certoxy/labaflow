import type { Metadata } from "next";
import "./globals.css";
import "./order-polish.css";
import "./promo-order.css";
import "./qr.css";
import ServiceEditEnhancer from "./ServiceEditEnhancer";
import NewOrderRouteEnhancer from "./NewOrderRouteEnhancer";

export const metadata: Metadata = {
  title: "LabaFlow",
  description: "Laundry management, simplified.",
};

export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return <html lang="en"><body><ServiceEditEnhancer/><NewOrderRouteEnhancer/>{children}</body></html>;
}
