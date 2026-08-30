import type { Metadata, Viewport } from "next";
import "./globals.css";
import "./brand.css";
import "./sidebar.css";
import "./order-polish.css";
import "./promo-order.css";
import "./qr.css";
import "./camera-qr.css";
import "./receipt-print.css";
import "./mobile.css";
import "./order-mobile-v3.css";
import "./new-order-desktop.css";
import "./orders-mobile.css";
import "./checkout-mobile.css";
import "./receipt-page.css";
import "./customers-mobile.css";
import "./loyalty-mobile.css";
import "./reports-mobile.css";
import "./services-mobile.css";
import "./sync-mobile.css";
import "./organization-admin.css";
import "./admin-subpages-mobile.css";
import "./subscription-admin.css";
import "./pwa-install.css";
import "./customer/customer.css";
import ServiceEditEnhancer from "./ServiceEditEnhancer";
import NewOrderRouteEnhancer from "./NewOrderRouteEnhancer";
import SidebarEnhancer from "./SidebarEnhancer";
import CameraQrEnhancer from "./CameraQrEnhancer";
import NewCustomerEnhancer from "./NewCustomerEnhancer";
import NewOrderCustomerEnhancer from "./NewOrderCustomerEnhancer";
import OfflineEnhancer from "./OfflineEnhancer";
import ReceiptEnhancer from "./ReceiptEnhancer";
import OrdersReceiptEnhancer from "./OrdersReceiptEnhancer";
import AutoPrintReceiptEnhancer from "./AutoPrintReceiptEnhancer";
import CheckoutEnhancer from "./CheckoutEnhancer";
import AdminSubpagesEnhancer from "./AdminSubpagesEnhancer";
import CustomerPwaEnhancer from "./CustomerPwaEnhancer";
import OrgPwaEnhancer from "./OrgPwaEnhancer";

export const metadata: Metadata = {
  title: "LabaFlow",
  description: "Flowing clean. Simplified business.",
  manifest: "/manifest.webmanifest",
  icons: {icon:"/labaflow-icon.svg",apple:"/labaflow-icon.svg"},
  appleWebApp: {capable:true,title:"LabaFlow",statusBarStyle:"default"},
};
export const viewport: Viewport = {width:"device-width",initialScale:1,viewportFit:"cover",themeColor:"#0c3554"};
export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) {return <html lang="en"><body><ServiceEditEnhancer/><NewOrderRouteEnhancer/><SidebarEnhancer/><CameraQrEnhancer/><NewCustomerEnhancer/><NewOrderCustomerEnhancer/><OfflineEnhancer/><ReceiptEnhancer/><OrdersReceiptEnhancer/><AutoPrintReceiptEnhancer/><CheckoutEnhancer/><AdminSubpagesEnhancer/><CustomerPwaEnhancer/><OrgPwaEnhancer/>{children}</body></html>}
