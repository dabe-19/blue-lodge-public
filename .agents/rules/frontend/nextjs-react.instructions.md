---
trigger: glob
globs:{frontend,web,src,components,**/{app,pages}}/**/*.{tsx,ts,jsx,js}
---

# Next.js & React Coding Standards

- **App Router Conventions**: Strictly adhere to the Next.js App Router paradigm. Use `page.tsx` for route entry points, `layout.tsx` for shared UI, and keep standard components in the `src/components/` directory.
- **Client vs. Server Components**: Default to React Server Components (RSC) for data fetching and layout. Only add the `'use client'` directive at the top of files that strictly require interactivity, DOM manipulation, or React hooks (e.g., `useState`, `useEffect`).
- **Separation of API Logic**: Do not write raw `fetch` calls directly inside UI components. Abstract all backend communication into dedicated library files (e.g., `src/lib/api.ts`) to maintain a clean boundary between UI and data fetching.
- **Strict Typing**: Use TypeScript interfaces or `type` aliases for all component props, state variables, and API responses. Avoid `any`.
- **Reusable Components**: Build small, focused, and reusable components. If a UI element (like a Modal or Table) is used in multiple views, ensure it is completely decoupled from page-specific logic.
