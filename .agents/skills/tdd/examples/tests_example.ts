// Good Test Example: Verifies observable public outcome behavior
test("user can checkout with valid cart", async () => {
    const cart = createCart();
    cart.add(product);
    const result = await checkout(cart, paymentMethod);
    expect(result.status).toBe("confirmed");
});

// Bad Test Example (AVOID): Coupled heavily to internal class details
test("checkout calls paymentService.process", async () => {
    const mockPayment = jest.mock(paymentService);
    await checkout(cart, payment);
    expect(mockPayment.process).toHaveBeenCalledWith(cart.total);
});