import type { Metadata } from "next";
import "./globals.css";
import "./qr.css";

export const metadata: Metadata = {
  title: "LabaFlow",
  description: "Laundry management, simplified.",
};

export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return <html lang="en"><body>{children}</body></html>;
}
