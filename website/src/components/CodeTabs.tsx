import { useState, type ReactNode } from "react";
import { PiArrowRightLight, PiBirdLight, PiCheckLight, PiCopyLight } from "react-icons/pi";
import { SiC, SiEffect, SiGo, SiKotlin, SiOpenjdk, SiPython, SiRust, SiSwift, SiTypescript, SiZig } from "react-icons/si";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";

/** Language marks for the tabs, by name (an island's props must be serializable). Roc has no mark in the set: its bird. */
const icons = {
  typescript: SiTypescript,
  effect: SiEffect,
  rust: SiRust,
  python: SiPython,
  go: SiGo,
  swift: SiSwift,
  java: SiOpenjdk,
  kotlin: SiKotlin,
  roc: PiBirdLight,
  zig: SiZig,
  c: SiC,
} as const;

export interface Tab {
  /** Also the name of the Astro slot holding this tab's pre-highlighted code. */
  value: string;
  label: string;
  caption?: string;
  icon?: keyof typeof icons;
  /** A page to read more, shown after the caption: its link text and address. */
  more?: { label: string; href: string };
  /**
   * How to install it, one line above the code: a shell command (with a
   * prompt), a line for a build file, or a note; all but notes can be copied.
   */
  install?: { text: string; kind: "shell" | "file" | "note" };
}

/** A tab's install line, with a button that copies it. */
function Install({ text, kind }: NonNullable<Tab["install"]>) {
  const [copied, setCopied] = useState(false);
  const copy = async () => {
    try {
      await navigator.clipboard.writeText(text);
      setCopied(true);
      setTimeout(() => setCopied(false), 1500);
    } catch {
      // Nothing to do: the text is there to select.
    }
  };
  const Icon = copied ? PiCheckLight : PiCopyLight;
  return (
    <div className="mb-3 flex min-h-10 items-center gap-2.5 rounded-[10px] border border-line bg-paper px-3.5 font-mono text-[0.82rem] text-ink">
      {kind === "shell" && (
        <span aria-hidden="true" className="select-none text-ink-3">
          $
        </span>
      )}
      <code className={`min-w-0 flex-1 overflow-x-auto py-2 whitespace-nowrap ${kind === "note" ? "font-sans text-[0.88rem] text-ink-2" : ""}`}>
        {text}
      </code>
      {kind !== "note" && (
        <button
          type="button"
          onClick={copy}
          aria-label={copied ? "Copied" : "Copy"}
          title={copied ? "Copied" : "Copy"}
          className="-mr-1 shrink-0 rounded-md p-1 text-ink-3 transition-colors hover:text-ink"
        >
          <Icon aria-hidden="true" className="size-4" />
        </button>
      )}
    </div>
  );
}

type Props = { tabs: Tab[] } & Record<string, ReactNode | Tab[]>;

const trigger = "tab-brush inline-flex items-center gap-1.5 px-1 pb-1.5 text-[0.98rem] font-medium text-ink-3 transition-colors hover:text-ink data-active:text-ink";
// All panels share one grid cell, so the area is as tall as the tallest one and
// switching tabs never changes the layout (or the washes painted around it).
const panel =
  "col-start-1 row-start-1 min-w-0 text-base data-[state=inactive]:invisible data-[state=inactive]:pointer-events-none";

export default function CodeTabs({ tabs, ...slots }: Props) {
  return (
    <Tabs defaultValue={tabs[0].value} className="min-w-0 gap-4">
      <TabsList variant="line" className="h-auto flex-wrap justify-start gap-x-5 gap-y-2 p-0 group-data-horizontal/tabs:h-auto">
        {tabs.map((t) => {
          const Icon = t.icon && icons[t.icon];
          return (
            <TabsTrigger key={t.value} value={t.value} className={trigger}>
              {Icon && <Icon aria-hidden="true" className="size-[0.95em] shrink-0" />}
              {t.label}
            </TabsTrigger>
          );
        })}
      </TabsList>
      <div className="grid grid-cols-[minmax(0,1fr)]">
        {tabs.map((t) => (
          <TabsContent key={t.value} value={t.value} forceMount className={panel}>
            {t.install && <Install {...t.install} />}
            {slots[t.value] as ReactNode}
            {(t.caption || t.more) && (
              <p className="mt-4 text-[0.92rem] text-ink-3">
                {t.caption}
                {t.more && (
                  <>
                    {t.caption && " "}
                    <a href={t.more.href} className="prose-link inline-flex items-center gap-1 whitespace-nowrap text-ink">
                      {t.more.label}
                      <PiArrowRightLight aria-hidden="true" className="size-[0.9em]" />
                    </a>
                  </>
                )}
              </p>
            )}
          </TabsContent>
        ))}
      </div>
    </Tabs>
  );
}
