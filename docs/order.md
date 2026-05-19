# order

One chokepoint for every order your brain issues. Instead of calling
`Player.PrepareUnitOrders` scattered across your code, you call `Order.Issue`
and get validation, a duplicate guard, and a consistent identifier on every
order for free.

## Why route orders through one place

- **Validation** - each order type needs different fields (a target, a
  position, an ability). `Order.Issue` checks them before dispatch, so a
  malformed order fails fast instead of silently doing nothing.
- **Duplicate guard** - issuing the same logical order twice in quick
  succession is a no-op. Orders carry an identifier `<hero>-<layer>-<intent>`
  and a 2.5s pending registry dedupes by it.
- **Unlearned-ability trap** - `Ability.IsReady` returns true for an ability
  you have not learned yet. `Order.Issue` also checks the level, so an order
  for a level-0 ability is rejected instead of jamming the registry.

## Setup

Once, during init, chain the lib's handlers into your callbacks table:

```lua
local Order = require("lib.order")
local callbacks = {}
Order.Wire(callbacks)   -- adds OnUpdateEx + OnPrepareUnitOrders handlers
return callbacks
```

## Issuing an order

```lua
Order.Issue({
    hero       = "Lina",
    layer      = "agg",                 -- "agg" or "def"
    intent     = "combo_q",
    order_type = Enum.UnitOrder.DOTA_UNIT_ORDER_CAST_TARGET,
    unit       = my_hero,
    target     = enemy,
    ability    = my_q,
})
```

Returns `true` if dispatched, `false` on a validation failure or a duplicate.
`layer = "def"` forces `execute_fast` on, so a defensive order beats the
humanizer queue.

## API

| Function | Purpose |
|----------|---------|
| `Order.Issue(spec)` | validate + dispatch an order |
| `Order.Identifier(hero, layer, intent)` | build the canonical id string |
| `Order.IsPending(prefix)` | is any in-flight order's id under this prefix |
| `Order.SetStrict(bool)` | strict mode raises on a missing field (default on) |
| `Order.Wire(callbacks)` | chain the handlers into your callbacks table |
