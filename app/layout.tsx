import type { Metadata, Viewport } from "next";
import "./globals.css";
import "./sidebar.css";
import "./order-polish.css";
import "./promo-order.css";
import "./qr.css";
import "./camera-qr.css";
import "./receipt-print.css";
import ServiceEditEnhancer from "./ServiceEditEnhancer";
import NewOrderRouteEnhancer from "./NewOrderRouteEnhancer";
import SidebarEnhancer from "./SidebarEnhancer";
import CameraQrEnhancer from "./CameraQrEnhancer";
import NewCustomerEnhancer from "./NewCustomerEnhancer";
import NewOrderCustomerEnhancer from "./NewOrderCustomerEnhancer";
import OfflineEnhancer from "./OfflineEnhancer";

export const metadata: Metadata = {
  title: "LabaFlow",
  description: "Laundry management, simplified.",
  manifest: "/manifest.webmanifest",
  icons: {icon:"/labaflow-icon.svg",apple:"/labaflow-icon.svg"},
  appleWebApp: {capable:true,title:"LabaFlow",statusBarStyle:"default"},
};
export const viewport: Viewport = {themeColor:"#0f766e"};
export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) {return <html lang="en"><body><ServiceEditEnhancer/><NewOrderRouteEnhancer/><SidebarEnhancer/><CameraQrEnhancer/><NewCustomerEnhancer/><NewOrderCustomerEnhancer/><OfflineEnhancer/>{children}</body></html>}
