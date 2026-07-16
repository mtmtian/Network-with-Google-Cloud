# VPS Stock Monitor

`tools/vps_stock.py` is a read-only inventory monitor. It checks public provider pages and recent social leads; it never logs in, adds a product to a cart, submits an order, or changes a server.

Run it from the repository root:

```bash
python3 tools/vps_stock.py --state-file ~/.cache/network-node/vps-stock.json
```

The state file is intentionally outside the repository. The monitor reports only new availability/lead transitions and meaningful source exceptions. Social posts and third-party catalog observations remain leads until the provider's official page is checked.

The official matrix includes the ZgoVPS Los Angeles AMD Optimised Starter at `$18/quarter` (`$6/month` equivalent), tracked separately from the `$52/year` special-offer page.
It also includes DediOne `LAX.VPS.CMIN2.1C1G10G-Annual` at `$29.99/year`; the official product card exposes an order action but no numeric inventory count.

Validation for monitor changes:

```bash
python3 -m py_compile tools/vps_stock.py
python3 -m unittest tests.test_vps_stock
```
