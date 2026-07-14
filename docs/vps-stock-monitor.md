# VPS Stock Monitor

`tools/vps_stock.py` is a read-only inventory monitor. It checks public provider pages and recent social leads; it never logs in, adds a product to a cart, submits an order, or changes a server.

Run it from the repository root:

```bash
python3 tools/vps_stock.py --state-file ~/.cache/network-node/vps-stock.json
```

The state file is intentionally outside the repository. The monitor reports only new availability/lead transitions and meaningful source exceptions. Social posts and third-party catalog observations remain leads until the provider's official page is checked.

Validation for monitor changes:

```bash
python3 -m py_compile tools/vps_stock.py
python3 -m unittest tests.test_vps_stock
```
