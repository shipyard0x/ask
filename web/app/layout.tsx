import type { Metadata } from "next";
import "./globals.css";
import { Providers } from "./providers";

const TITLE = "ASK — hold it when the clock stops";
const DESCRIPTION =
  "Every ask costs 10% more than the last. Take it and the holder before you leaves with 5%, immediately. Hold it when the clock hits zero and you take half the pot.";

export const metadata: Metadata = {
  title: TITLE,
  description: DESCRIPTION,
  openGraph: { title: TITLE, description: DESCRIPTION, type: "website" },
  twitter: { card: "summary", title: TITLE, description: DESCRIPTION, site: "@AskonRH", creator: "@AskonRH" },
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en">
      <body>
        <Providers>{children}</Providers>
      </body>
    </html>
  );
}
