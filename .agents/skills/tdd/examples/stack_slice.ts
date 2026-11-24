// Step-by-Step Tracer Bullet Implementation Lifecycle Reference:

// Cycle 1: Verify empty constraints
// Test: expect(stack.isEmpty()).toBe(true);
// Impl: isEmpty() { return true; }

// Cycle 2: Add vertical slice capability for pushing items onto stack
// Test: stack.push('itemA'); expect(stack.isEmpty()).toBe(false);
// Impl: 
//   push(item) { this.items.push(item); }
//   isEmpty() { return this.items.length === 0; }