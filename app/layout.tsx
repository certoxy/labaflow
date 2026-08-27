import type { Metadata } from "next";
import "./globals.css";
import "./order-polish.css";
import "./qr.css";
import ServiceEditEnhancer from "./ServiceEditEnhancer";

export const metadata: Metadata = {
  title: "LabaFlow",
  description: "Laundry management, simplified.",
};

export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return <html lang="en"><body><ServiceEditEnhancer/>{children}</body></html>;
}
