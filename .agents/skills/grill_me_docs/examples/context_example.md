# Sample Context Layout Schema

```markdown
# Fulfillment Context

This context is responsible for dispatching inventory items out of warehouse hubs.

## Language

**Manifest**:
The definitive structural packing list assigned to an individual outbound carrier vehicle.
_Avoid_: Shipping log, delivery sheet, truck manifest

## Relationships

- A **Shipment** populates exactly one outbound cargo **Manifest**.