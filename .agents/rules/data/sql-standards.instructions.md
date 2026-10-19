---
trigger: glob
globs:{**/*.sql,**/migrations/**,**/*{Repository,Dao}*.{cs,ts,js,py,go,rs,java,kt}}

---

# SQL & Data-Access Standards

- **Parameterized Queries Always**: Never interpolate user input into SQL strings. Use the driver's parameter binding (`$1`, `?`, `:name`) without exception. String concatenation into SQL is a security defect (OWASP A03).
- **Migrations Are Append-Only**: Once a migration is merged to main, never edit it. Write a new migration to correct prior ones. Use a tool (`alembic`, `flyway`, `sqitch`, `goose`, `prisma migrate`) — do not hand-edit schemas in production.
- **Reversible Migrations**: Every `up` migration ships with a tested `down` migration unless explicitly marked irreversible (and document why in the migration file header).
- **Naming**: `snake_case` for tables and columns. Plural table names (`users`, `orders`). Foreign keys named `<referenced_table>_id`. Indexes prefixed `idx_`, unique constraints `uq_`, foreign keys `fk_`.
- **Explicit Columns**: Never `SELECT *` in application code. List columns by name so schema changes don't silently break consumers or leak new fields.
- **Joins Over Subqueries**: Prefer explicit `JOIN ... ON` over correlated subqueries when both express the same intent. Joins are more optimizer-friendly in most engines.
- **Indexes**: Every `WHERE`, `JOIN`, and `ORDER BY` column on a hot path must be backed by an index. Verify with `EXPLAIN` (or `EXPLAIN ANALYZE`) before merging non-trivial queries.
- **Transactions**: Wrap multi-statement writes in a transaction. Set the appropriate isolation level explicitly when defaults don't fit (e.g., `SERIALIZABLE` for financial counters).
- **N+1 Detection**: Eager-load related data (`JOIN`, `IN (...)`, ORM `select_related`/`include`) when iterating. Add a query-count assertion in integration tests for hot paths.
- **No Soft-Delete By Default**: Prefer `archived_at` columns or a separate audit/history table over a global `deleted_at` filter that every query must remember to apply.
- **Time Zones**: Store timestamps as UTC (`TIMESTAMPTZ` in PostgreSQL). Convert to local zones at the presentation boundary only.
- **Secrets**: Database credentials live in environment variables or a secret manager — never in committed `.sql` files or migration scripts.
