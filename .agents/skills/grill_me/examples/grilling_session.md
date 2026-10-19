# Sample Grilling Sequence

**User:** "Let's set up a cron job to sync the inventory table nightly."
**Agent:** "When the nightly sync runs, how should we handle a partial network timeout mid-transaction?
Recommendation: Use a staging snapshot table and swap it atomically via a transaction rename so a partial failure doesn't leave the production inventory corrupted."

**User:** "We should use Kafka for the real-time event bus."
**Agent:** "Given the existing RabbitMQ infrastructure for queues, what is the incremental business value of introducing Kafka? Consider the added operational overhead and learning curve.
Recommendation: Stay with RabbitMQ for now. Add Kafka only if message volume exceeds 10k/second or if we require ordered, exactly-once per partition semantics that RabbitMQ cannot provide."

**User:** "I plan to add an index on the `email` column to speed up lookups."
**Agent:** "If we add an index on `email`, should we also enforce a unique constraint on that column? Without it, we could have duplicate emails, but with it, we cannot support shared inboxes or alias addresses.
Recommendation: Add a unique index and a separate `email_aliases` table to support the shared inbox use case without compromising lookup performance."

**User:** "We should switch from REST endpoints to GraphQL for the client API."
**Agent:** "If we migrate to GraphQL, what is our strategy for preventing N+1 query problems on complex document fetches?
Recommendation: Implement query cost analysis at the GraphQL layer and enforce a depth/complexity threshold to reject expensive queries at runtime."

**User:** "Let's implement a background job system using Celery."
**Agent:** "If the Celery worker nodes crash during a high-load period, what prevents us from losing messages that are currently in the processing queue?
Recommendation: Configure persistent storage for the Celery broker and enable task acknowledgment with automatic retries on failure to ensure message durability."
