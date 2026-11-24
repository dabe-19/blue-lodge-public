"""George trading layer: policy engine, plans, journal and the six agent tools.

Money-path rule for everything in this package: fail closed. Missing data, a stale
price, an unknown tier or an unreadable ledger blocks new risk; it never permits it.
"""
