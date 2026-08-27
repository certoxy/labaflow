import type { Metadata } from "next";
import "./globals.css";
import "./sidebar.css";
import "./order-polish.css";
import "./promo-order.css";
import "./qr.css";
import "./camera-qr.css";
import ServiceEditEnhancer from "./ServiceEditEnhancer";
import NewOrderRouteEnhancer from "./NewOrderRouteEnhancer";
import SidebarEnhancer from "./SidebarEnhancer";
import CameraQrEnhancer from "./CameraQrEnhancer";
import NewCustomerEnhancer from "./NewCustomerEnhancer";

export const metadata: Metadata = {
  title: "LabaFlow",
  description: "Laundry management, simplified.",
};

export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return <html lang="en"><body><ServiceEditEnhancer/><NewOrderRouteEnhancer/><SidebarEnhancer/><CameraQrEnhancer/><NewCustomerEnhancer/>{children}</body></html>;
}
