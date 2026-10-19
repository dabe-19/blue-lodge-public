---
name: tdd
description: Test-driven development with red-green-refactor loop. Use when user wants to build features or fix bugs using TDD, mentions "red-green-refactor", wants integration tests, or asks for test-first development.
---

# Test-Driven Development

## Goal
Construct stable, highly maintainable application behaviors and prevent structural entropy by executing a continuous, fine-grained, test-first red-green-refactor workflow utilizing thin vertical slices.

## Instructions
1. **Interface Planning:** Evaluate architectural changes through the lens of module depth (small interface hiding vast implementation complexity). Design interfaces that accept injected dependencies, return deterministic results rather than generating unmanaged side effects, and expose minimal surface areas. Get upfront confirmation on the public interface layout.
2. **Boundary Mocking Architecture:** Establish system boundaries strictly. Mock out external APIs, physical databases, system clock times, or unpredictable random generation. Never mock internal module collaborators, local pure classes, or domain structures under your direct control.
3. **The Vertical Slice Rule (Tracer Bullet):** Isolate a single, thin end-to-end path through all integration layers (schema, API, core logic, interface). Write exactly ONE test defining the public signature for this behavior.
4. **The Execution Loop Phase:**
   - **RED:** Run the test suite to observe the new test fail cleanly. Verify the failure matches the expected behavior absence.
   - **GREEN:** Write the absolute minimum implementation required to make the failing test pass. Avoid speculative optimizations or writing code ahead of subsequent tests.
5. **The Refactor Cycle:** Once on GREEN, evaluate code against refactoring targets. Eradicate code duplication, deepen modules by shifting complex private details behind the public interface, resolve feature envy by co-locating data with its processing operations, and replace raw primitives with explicit domain value objects. Re-verify the test suite after every in-place modification.

## Examples
### Behavioral Integration Test (Good)
```typescript
test("user can checkout with valid cart", async () => {
  const cart = createCart();
  cart.add(product);
  const result = await checkout(cart, paymentMethod);
  expect(result.status).toBe("confirmed");
});