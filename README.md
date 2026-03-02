# Shopify Metafield Scanner — Ruby Script

Scans all metafields in a Shopify store and generates a CSV report with size analysis, usage warnings, and breakdowns by resource type.

---

## Before You Start

This is a command-line script — you'll need to run it in a **terminal** (also called command line or console). If you haven't used a terminal before, here's how to open one:

- **macOS** — Open **Terminal** (search for "Terminal" in Spotlight, or find it in Applications → Utilities)
- **Windows** — Open **PowerShell** (right-click the Start button → "Windows PowerShell") or **Command Prompt** (search for "cmd")
- **Linux** — Open your terminal emulator (usually `Ctrl + Alt + T`)

All the commands in this guide are meant to be typed into the terminal and run by pressing Enter.

---

## 1. Install Ruby

The script requires **Ruby 3.0+** (works with 2.7 but 3.0+ recommended). Check if you already have it:

```bash
ruby --version
```

If you see `ruby 3.x.x` you're good — skip to [Quick Start](#2-quick-start).

### macOS

macOS ships with a system Ruby, but it's outdated and locked down. Install a proper version:

**Option A — Homebrew (simplest):**
```bash
# Install Homebrew if you don't have it
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# Install Ruby
brew install ruby

# Add to your PATH (add this line to ~/.zshrc or ~/.bash_profile)
echo 'export PATH="/opt/homebrew/opt/ruby/bin:$PATH"' >> ~/.zshrc
source ~/.zshrc

# Verify
ruby --version
```

**Option B — rbenv (if you work with multiple Ruby versions):**
```bash
brew install rbenv ruby-build
rbenv install 3.3.0
rbenv global 3.3.0

# Add to shell (add to ~/.zshrc or ~/.bash_profile)
echo 'eval "$(rbenv init -)"' >> ~/.zshrc
source ~/.zshrc

ruby --version
```

### Windows

**Option A — RubyInstaller (recommended):**
1. Download from [https://rubyinstaller.org/downloads/](https://rubyinstaller.org/downloads/)
2. Choose **Ruby+Devkit 3.3.x (x64)** — the one with Devkit
3. Run the installer, check "Add Ruby to PATH"
4. On the final screen, run the MSYS2 setup (press Enter for default)
5. Open a new Command Prompt or PowerShell:
```powershell
ruby --version
```

**Option B — WSL (if you prefer Linux on Windows):**
```powershell
# Enable WSL (run PowerShell as Admin)
wsl --install

# Then inside Ubuntu:
sudo apt update
sudo apt install ruby-full
ruby --version
```

### Linux (Ubuntu/Debian)

```bash
sudo apt update
sudo apt install ruby-full
ruby --version
```

If your distro ships an older version:
```bash
# Using rbenv
sudo apt install git curl libssl-dev libreadline-dev zlib1g-dev
curl -fsSL https://github.com/rbenv/rbenv-installer/raw/HEAD/bin/rbenv-installer | bash

echo 'export PATH="$HOME/.rbenv/bin:$PATH"' >> ~/.bashrc
echo 'eval "$(rbenv init -)"' >> ~/.bashrc
source ~/.bashrc

rbenv install 3.3.0
rbenv global 3.3.0
ruby --version
```

### Linux (Fedora/RHEL/CentOS)

```bash
sudo dnf install ruby ruby-devel
ruby --version
```

---

## 2. Quick Start

```bash
# 1. Download/clone this folder

# 2. Rename the example config
cp config-example.yml config.yml

# 3. Edit the config — 3 fields required
nano config.yml
#    → set store.domain
#    → set store.client_id
#    → set store.client_secret

# 4. Run
ruby scan_metafields.rb

# 5. Check results
ls ./results/
```

That's it. The script uses only Ruby standard library — no gems required.

### Optional: Fancy Progress Bar

If you want a visual progress bar instead of the basic spinner animation, install the `tty-progressbar` gem:

```bash
gem install tty-progressbar
```

Then in `config.yml`, set:
```yaml
progress:
  style: "bar"   # instead of "spinner"
```

This is completely optional — the built-in spinner works with zero dependencies.

---

## 3. Setup Your Shopify App (Dev Dashboard)

1. Go to the **[Shopify Dev Dashboard](https://dev.shopify.com)** and sign in
2. Click **Apps → Create an app** → name it "Metafield Scanner"
3. Under **Configuration → Admin API access scopes**, add:
   - `read_products` — products, variants & collections
   - `read_customers` — customers, companies (B2B)
   - `read_content` — articles, blogs, pages
   - `read_metaobject_definitions` — metaobjects
   - `read_locales` — shop-level metafields
   - `read_locations` — locations (optional)
   - `read_orders` — orders (optional, can be very large)
   - `read_draft_orders` — draft orders (optional)
4. Create an **app version** with these scopes
5. **Install** the app on your store (Distribution → Custom → select your store)
6. Go to **Settings → Client credentials** and copy:
   - **Client ID** → paste in `config.yml` as `store.client_id`
   - **Client Secret** → paste in `config.yml` as `store.client_secret` (starts with `shpss_`)

The script uses these credentials to automatically fetch a short-lived access token each time it runs. No manual token management needed.

---

## 4. Config Reference

### Store Connection

**Single store** — use the `store` key:
```yaml
store:
  domain: "my-store.myshopify.com"
  client_id: "your-client-id"
  client_secret: "shpss_..."
  api_version: "2026-01"
```

**Multiple stores** — use the `stores` key (a list):
```yaml
stores:
  - domain: "store-one.myshopify.com"
    client_id: "aaaaaaaaaa"
    client_secret: "shpss_aaaaaaaaaa"
    api_version: "2026-01"

  - domain: "store-two.myshopify.com"
    client_id: "bbbbbbbbbb"
    client_secret: "shpss_bbbbbbbbbb"
    api_version: "2026-01"
```

Each store needs its own app in the Dev Dashboard. When scanning multiple stores, each store's CSV is prefixed with its domain and all other settings (resources, filters, thresholds) apply to every store.

| Setting | Required | Description |
|---|---|---|
| `domain` | ✅ | Your `.myshopify.com` domain (no `https://`) |
| `client_id` | ✅ | Client ID from Dev Dashboard → Settings |
| `client_secret` | ✅ | Client Secret from Dev Dashboard (starts with `shpss_`) |
| `api_version` | | Shopify API version (default: `2026-01`) |

### Resources
Toggle `true`/`false` to include/exclude resource types from the scan:

`product`, `product_variant`, `collection`, `customer`, `order`, `draft_order`, `page`, `article`, `blog`, `shop`, `company`, `company_location`, `location`

### Scan Method
| Setting | Options | Description |
|---|---|---|
| `scan.method` | `bulk` / `graphql` | `bulk` for large stores (async, no throttling), `graphql` for small stores |

### Output
| Setting | Options | Description |
|---|---|---|
| `output.report_type` | `summary` / `detailed` | Grouped aggregates vs every individual metafield |
| `output.split_by_resource` | `true` / `false` | One CSV per resource type, or everything in one file |
| `output.sort_by` | column name | Sort results by any output column |
| `output.sort_order` | `asc` / `desc` | Sort direction |

### Progress Display
| Setting | Options | Description |
|---|---|---|
| `progress.style` | `spinner` / `bar` / `none` | `spinner` = built-in animation (no gems), `bar` = tty-progressbar gem, `none` = silent |

### Filters
| Setting | Description |
|---|---|
| `filters.namespaces` | Only scan these namespaces |
| `filters.exclude_namespaces` | Skip these namespaces |
| `filters.specific_keys` | Only scan `namespace.key` combos |
| `filters.min_total_bytes` | Hide metafields smaller than this |

### Thresholds
| Setting | Description |
|---|---|
| `thresholds.warning_percent` | Flag when value exceeds this % of Shopify's limit |
| `thresholds.flag_above_bytes` | Flag individual values above this size |

---

## 5. Output

CSV files are saved to `./results/` (configurable).

**Single store** — files go directly in the results folder:
```
results/
  my-store_metafields_20260301_143022.csv
```

**Multiple stores** — each file is prefixed with the store domain:
```
results/
  store-one_metafields_20260301_143022.csv
  store-two_metafields_20260301_143022.csv
```

**Split by resource** (`split_by_resource: true`): Separate CSV per resource type:
```
results/
  store-one_metafields_product_20260301_143022.csv
  store-one_metafields_collection_20260301_143022.csv
  store-two_metafields_product_20260301_143022.csv
  store-two_metafields_collection_20260301_143022.csv
```

### Summary Mode Columns
`resource_type`, `namespace`, `key`, `metafield_type`, `count`, `total_bytes`, `avg_bytes`, `max_bytes`, `min_bytes`, `type_limit`, `max_usage_pct`, `warnings`

### Detailed Mode Columns
`resource_type`, `owner_id`, `owner_name`, `namespace`, `key`, `metafield_type`, `value_bytes`, `type_limit`, `usage_percent`, `warning`, `value_preview`

---

## 6. CLI Options

```bash
ruby scan_metafields.rb                    # uses ./config.yml
ruby scan_metafields.rb -c my_config.yml   # custom config path
ruby scan_metafields.rb --version          # show version
ruby scan_metafields.rb --help             # show help
```

---

## 7. Troubleshooting

**"Config file not found"** — Make sure you've renamed `config-example.yml` to `config.yml` in the same folder as the script.

**"Authentication failed"** — Your client credentials were rejected. Go to the [Dev Dashboard](https://dev.shopify.com) → your app → Settings → Client credentials and verify your `client_id` and `client_secret`. Make sure the app is installed on the store.

**"Missing API scope for X"** — The scanner auto-detects missing scopes. Go to the Dev Dashboard → your app → Configuration → Admin API access scopes, add the scope listed in the warning, create a new app version, and reinstall.

**Bulk operation timeout** — Large stores can take several minutes. Increase `scan.max_wait_time` in config.yml (default: 600 seconds).

**"YAML syntax error"** — Tabs are not allowed in YAML. Use spaces only. Paste your config into [yamlchecker.com](https://yamlchecker.com) to find the issue.

**Rate limiting (GraphQL mode)** — Switch to `scan.method: "bulk"` for large stores. The bulk API runs async on Shopify's servers with no throttling.

**"tty-progressbar not found"** — Either install it (`gem install tty-progressbar`) or switch to `progress.style: "spinner"` in config.yml.

**"api_token is no longer used"** — You have an old config. Replace `api_token` with `client_id` and `client_secret` from the Dev Dashboard. Legacy custom apps created before January 2026 still work, but new apps require the client credentials flow.

---

## 8. Requirements Summary

| Requirement | Notes |
|---|---|
| **Ruby** | 3.0+ recommended, 2.7 minimum |
| **Gems** | None required (stdlib only) |
| **Optional gem** | `tty-progressbar` — only if you want `progress.style: "bar"` |
| **Shopify** | App created via [Dev Dashboard](https://dev.shopify.com) with read-only Admin API scopes |
| **Network** | HTTPS access to `*.myshopify.com` |

---

## 9. Author

Made by [Karim Tarek](https://ca.linkedin.com/in/karimtarek). I'm a Shopify developer based in Canada, building tools and apps around the Shopify ecosystem through.

I also built [FieldsRaven](https://apps.shopify.com/fieldsraven) — a Shopify app that exposes the Metafields API on the storefront through an app proxy, so theme developers can create and update metafields on-the-fly using Liquid and JS. It's useful for things like wishlists, customer preferences, registration forms, and other storefront features that need to write data back to metafields. Docs are at [docs.fieldsraven.app](https://docs.fieldsraven.app).

- [GitHub](https://github.com/karimmtarek)
- [LinkedIn](https://ca.linkedin.com/in/karimtarek)
- [☕ Buy me a coffee on Ko-fi](https://ko-fi.com/karimtarek)

---

## 10. License

MIT License — see [LICENSE](LICENSE) for details. Use it, fork it, ship it.
