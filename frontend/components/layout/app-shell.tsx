"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { LayoutDashboard, BookOpen, Search, FolderGit2, FileCheck2, Workflow, FileBarChart2, Network, FlaskConical, GitBranch } from "lucide-react";

const navItems = [
  { href: "/", label: "Workspace", icon: LayoutDashboard },
  { href: "/knowledge", label: "项目知识", icon: BookOpen },
  { href: "/rag", label: "RAG 工作室", icon: Search },
  { href: "/repos", label: "Repos", icon: FolderGit2 },
  { href: "/action-drafts", label: "Drafts", icon: FileCheck2 },
  { href: "/workflow-runs", label: "Runs", icon: Workflow },
  { href: "/workspaces", label: "Reports", icon: FileBarChart2 },
  { href: "/code-graph", label: "Code Graph", icon: Network },
  { href: "/evals", label: "Evals", icon: FlaskConical }
];

export function AppShell({ children }: { children: React.ReactNode }) {
  const pathname = usePathname();
  return (
    <div className="rb-shell">
      <aside className="rb-navigation">
        <div className="rb-brand">
          <span className="rb-monogram" aria-hidden="true">RB</span>
          <div><strong>RepoBride</strong><span className="rb-brand-caption">ENGINEERING WORKSPACE</span></div>
        </div>
        <div className="rb-nav-caption" aria-hidden="true">WORKSPACE / 工作空间</div>
        <nav className="rb-nav-links" aria-label="主导航">
          {navItems.map(({ href, label, icon: Icon }) => (
            <Link key={href} href={href} aria-current={pathname === href ? "page" : undefined} className="rb-nav-link">
              <Icon size={18} strokeWidth={1.6} aria-hidden="true" />
              <span>{label}</span>
            </Link>
          ))}
        </nav>
        <div className="rb-nav-footer"><GitBranch size={16} aria-hidden="true" /><span>RepoBride<span className="rb-brand-caption">研发协作智能体</span></span></div>
      </aside>
      <main className="rb-content">{children}</main>
    </div>
  );
}
