---
trigger: always_on
---

# Architectural Standards & Design Patterns

- **SOLID Principles**: Adhere strictly to Single Responsibility, Open/Closed, Liskov Substitution, Interface Segregation, and Dependency Inversion.
- **Separation of Concerns**: Isolate business logic from data access, UI, and external integrations. Use DTOs (Data Transfer Objects) to pass data across boundaries.
- **Dependency Injection**: Pass dependencies (services, database contexts, loggers) via constructors. Classes should not instantiate their own complex dependencies.
- **Strategy Pattern**: When a class requires variable behaviors or algorithms, define an interface and inject concrete implementations rather than using large `if/switch` blocks.
- **Composition over Inheritance**: Favor composing complex objects from simpler, reusable components rather than building deep, brittle inheritance trees.
- **Fail Fast**: Validate inputs and state early. Throw exceptions or return error types at the boundary of your domain before processing begins.
