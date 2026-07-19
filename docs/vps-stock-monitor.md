# VPS Stock Monitor

`tools/vps_stock.py` is a read-only inventory monitor. It checks public
provider pages and recent social leads; it never logs in, adds a product to a
cart, submits an order, or changes a server.

Run it from the repository root:

```bash
python3 tools/vps_stock.py --state-file ~/.cache/network-node/vps-stock.json
```

The state file is intentionally outside the repository. The monitor reports
only new availability/lead transitions and meaningful source exceptions.
Social posts and third-party catalog observations remain leads until the
provider's official page is checked.

The official matrix includes the ZgoVPS Los Angeles AMD Optimised Starter at
`$18/quarter` (`$6/month` equivalent), tracked separately from the `$52/year`
special-offer page.
It also includes DediOne `LAX.VPS.CMIN2.1C1G10G-Annual` at `$29.99/year`; the
official product card exposes an order action but no numeric inventory count.

LightLayer keeps its whole catalog behind an account login, so its two Los
Angeles annual plans use the `manual` source kind: the monitor never fetches
them and reports the specs and price verified by hand, plus how old that
snapshot is. Past `stale_after_days` (30 by default) the source turns
`unknown`, surfacing as an exception that prompts a re-check.

- `lightlayer-lax-vp01-a-annual` — `LA-VP01-A`, `$24.99/year`, Premium line,
  20Mbps unmetered, 50GB NVMe, native IPv4
- `lightlayer-lax-vp04-l-a-annual` — `LA-VP04-L-A`, `$49.99/year`, Premium
  line, 1Gbps at 1TB/month, 50GB NVMe, native IPv4

Premium means CN2 for China Telecom and CMIN2 for China Unicom and Mobile.
Both promo plans are non-upgradeable and non-refundable. Re-verify at the URL
recorded on each source and bump `verified_on` when the snapshot changes.

Validation for monitor changes:

```bash
python3 -m py_compile tools/vps_stock.py
python3 -m unittest tests.test_vps_stock
```
