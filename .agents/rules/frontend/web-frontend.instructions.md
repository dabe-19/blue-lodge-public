---
trigger: glob
globs:**/*.{ts,tsx,js,jsx,vue}
---

# Frontend Coding Standards

- **Component Reusability**: Build small, focused components. Extract duplicated UI elements into shared generic components.
- **Type Safety**: Use TypeScript interfaces or types to define component props, state, and API responses. Avoid using `any`.
- **Accessibility (a11y)**: Write semantic HTML (e.g., `<button>` instead of `<div onClick="...">`). Include `aria-` attributes and `alt` tags where appropriate. Ensure applications are keyboard navigable.
- **Side Effects**: Isolate side effects (fetching data, subscribing to events) into dedicated lifecycle hooks or abstracted custom hooks/composables. Keep render functions pure.
- **Responsive Design**: Use CSS Flexbox/Grid and relative units (rem, vh, %) rather than hard-coding fixed pixel dimensions, ensuring layouts adapt to mobile and desktop viewports.
