import type { Metadata } from "next";
import { Barlow } from "next/font/google";
import "./globals.css";

const barlow = Barlow({
  subsets: ["latin"],
  weight: ["400", "500", "600", "700"],
  variable: "--police",
});

export const metadata: Metadata = {
  title: "Cycles de perçage",
  description: "Dépôt des exports de cycles de perçage et intégration en base",
  robots: { index: false, follow: false },
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="fr" className={barlow.variable}>
      <body>{children}</body>
    </html>
  );
}
