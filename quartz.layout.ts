import { PageLayout, SharedLayout } from "./quartz/cfg"
import * as Component from "./quartz/components"

const explorerOpts = {
  mapFn: (node: any) => {
    // Ano: promover semanas dos meses para filhos diretos
    if (node.isFolder && /^\d{4}$/.test(node.slugSegment)) {
      const weeks: any[] = []
      for (const child of node.children) {
        if (child.isFolder && /^\d{2}$/.test(child.slugSegment)) {
          weeks.push(...child.children)
        } else {
          weeks.push(child)
        }
      }
      node.children = weeks
    }
    // Semana: mostrar count e esconder episódios
    if (node.isFolder && /^W\d+$/.test(node.slugSegment)) {
      const count = node.children.filter((c: any) => !c.isFolder).length
      node.displayName = node.slugSegment + " (" + count + ")"
      node.children = []
    }
  },
}

// Components shared across all pages
export const sharedPageComponents: SharedLayout = {
  head: Component.Head(),
  header: [],
  afterBody: [],
  footer: Component.Footer({
    links: {
      GitHub: "https://github.com/thluiz",
    },
  }),
}

// Components for pages that display a single unique page (e.g. a regular note)
export const defaultContentPageLayout: PageLayout = {
  beforeBody: [
    Component.Breadcrumbs(),
    Component.ContentMeta(),
    Component.TagList(),
  ],
  left: [
    Component.PageTitle(),
    Component.MobileOnly(Component.Spacer()),
    Component.Search(),
    Component.Darkmode(),
    Component.Explorer(explorerOpts),
  ],
  right: [
    Component.Graph({
      localGraph: {
        showTags: true,
        removeTags: ["developer-tea"],
        depth: 2,
        scale: 1.1,
        opacityScale: 1,
        repelForce: 0.5,
        centerForce: 0.3,
        linkDistance: 30,
        fontSize: 0.6,
        focusOnHover: true,
      },
      globalGraph: {
        showTags: true,
        removeTags: ["developer-tea"],
        scale: 0.9,
        repelForce: 0.5,
        centerForce: 0.3,
        linkDistance: 30,
        fontSize: 0.6,
        opacityScale: 1,
        focusOnHover: true,
      },
    }),
    Component.DesktopOnly(Component.TableOfContents()),
    Component.Backlinks(),
  ],
}

// Components for pages that display lists of pages (e.g. tags or folders)
export const defaultListPageLayout: PageLayout = {
  beforeBody: [
    Component.Breadcrumbs(),
    Component.ArticleTitle(),
    Component.ContentMeta(),
  ],
  left: [
    Component.PageTitle(),
    Component.MobileOnly(Component.Spacer()),
    Component.Search(),
    Component.Darkmode(),
    Component.Explorer(explorerOpts),
  ],
  right: [],
}
