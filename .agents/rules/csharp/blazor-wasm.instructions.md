---
trigger: glob
globs:**/*{.razor,.cs}
---

# Blazor WebAssembly Standards

- **Component Architecture**: Keep `.razor` files focused on markup and binding. Move complex logic, state management, and API calls into code-behind files (`.razor.cs`) or injected view-model services.
- **State Management**: Do not rely on static variables for state in WASM. Use scoped services injected via Dependency Injection to manage user or component state.
- **Asynchronous Lifecycles**: Prefer `OnInitializedAsync` over `OnInitialized` when fetching data. Use `StateHasChanged()` sparingly and only when the framework cannot automatically detect state changes.
- **JavaScript Interop**: Isolate JS Interop calls (`IJSRuntime`) into dedicated wrapper services rather than scattering them throughout UI components.
