# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Mihomo-Gateway-Script is an automated deployment script for setting up Mihomo (Clash Meta) as a transparent gateway proxy. The script supports both Docker and Binary deployment modes on Linux systems (including Synology DSM).

**Core workflow:**
1. Client devices point their gateway and DNS to the Mihomo IP
2. All traffic flows through Mihomo gateway
3. Traffic is automatically routed based on rules (direct for domestic, proxy for international)
4. Supports auto-speed testing for optimal node selection

## Key Files

| File | Purpose | Lines |
|------|---------|-------|
| `deploy-mihomo-optimized.sh` | Main deployment script with all functionality | ~4066 |
| `config.yaml.tpl` | Basic configuration template | Simple proxy groups |
| `config-region.yaml.tpl` | Region-grouped configuration template | Country-based proxy groups |
| `README.md` | User documentation (Chinese) | Deployment guide and usage |

## Script Architecture

The script is organized into functional sections (marked by comment blocks):

### Core Sections
Sections are delimited by `# ====` banner comments. Line ranges below are the actual
ones in `deploy-mihomo-optimized.sh` (~4066 lines) — re-check them if the script grows.

| # | Section | Lines |
|---|---------|-------|
| 1 | Global Variables & Config | 7-44 |
| 2 | Error Code System | 45-103 |
| 3 | Utility Functions (logging, command execution, cleanup) | 104-263 |
| 4 | Enhanced Error Handling (`error_exit`, `run_cmd`, trap/cleanup hooks) | 264-338 |
| 5 | Input Validation & Security (IP/CIDR/URL/iface, path traversal, SSRF, command safety) | 339-791 |
| 6 | Interactive Input (prompt helpers with validation) | 792-884 |
| 7 | Sensitive Info Protection (`prompt_secret`, log redaction) | 885-1065 |
| 8 | Temp File Management | 1066-1086 |
| 9 | File Download & Verification (retry, checksum, ZIP extraction) | 1087-1233 |
| 10 | GitHub Proxy Wrapping | 1234-1278 |
| 11 | Configuration Management (backup, validation, load/save) | 1279-1491 |
| 12 | Platform & Architecture Detection | 1492-1572 |
| 13 | Network Detection (interface, gateway, subnet) | 1573-1649 |
| 14 | Country Detection & Dynamic Proxy Groups | 1650-1805 |
| 15 | Template Rendering (AWK) | 1806-1964 |
| 16 | Dependency Checks | 1965-2012 |
| 17 | Fetch Latest Version | 2013-2057 |
| 18 | Parameter Collection (interactive deployment wizard) | 2058-2216 |
| 19 | Dashboard Installation (metacubexd / zashboard) | 2217-2291 |
| 20 | DNS Config Generation | 2292-2363 |
| 21 | Rules Generation | 2364-2465 |
| 22 | Docker Mode Deployment (`deploy_docker_mode()`) | 2466-2523 |
| 23 | Binary Mode Deployment (binary install + systemd service) | 2524-2790 |
| 24 | Health Check | 2791-2865 |
| 25 | Auto-Update Management (cron) | 2866-3015 |
| 26 | Uninstall | 3016-3157 |
| 27 | Usage / CLI Help & Actions (`usage()`, `show_commands()`, menu) | 3158-3706 |
| 28 | Banner | 3707-3746 |
| 29 | Main Entry (argument parsing, action routing) | 3747-4066 |

### Critical Security Features
- **Input Validation**: All user inputs go through `validate_*` functions before use
- **Path Traversal Protection**: `validate_path()` blocks `..` and dangerous characters
- **SSRF Protection**: `sanitize_url()` and `is_private_ip()` prevent internal network access
- **Command Injection Defense**: `check_command_safety()` validates command patterns
- **Cleanup Hooks**: `trap cleanup EXIT INT TERM` ensures temp file cleanup
- **Secret Handling**: `prompt_secret()` hides sensitive input

## Development Commands

```bash
# Test run without making changes
./deploy-mihomo-optimized.sh --dry-run

# Verbose output for debugging
./deploy-mihomo-optimized.sh --verbose

# Deploy with specific mode
sudo ./deploy-mihomo-optimized.sh --mode docker
sudo ./deploy-mihomo-optimized.sh --mode binary

# Update Mihomo binary/container
sudo ./deploy-mihomo-optimized.sh --update

# Uninstall completely
sudo ./deploy-mihomo-optimized.sh --uninstall

# Enable/disable auto-update cron
sudo ./deploy-mihomo-optimized.sh --enable-auto-update
sudo ./deploy-mihomo-optimized.sh --disable-auto-update
```

## Configuration Management

### Template Variables
Templates use `{{VARIABLE}}` syntax. The script renders them using AWK:

- `{{CLASH_SECRET}}` - API authentication secret
- `{{SUB_URL}}` - Subscription URL
- `{{DNS_CONFIG}}` - Injected DNS configuration
- `{{UI_CONFIG}}` - Dashboard configuration
- `{{EXTERNAL_PORT}}` - API port (default 19090)
- `{{RULES_CONFIG}}` - Routing rules

### Storage Locations
**Docker mode:**
- Host config: `/opt/mihomo/` (or user-specified)
- DSM config: `/volume1/docker/mihomo/`
- Container config: `/root/.config/mihomo/`

**Binary mode:**
- Config dir: `/opt/mihomo/` (default; user can override in the wizard) — main file `config.yaml`
  (older releases used `/etc/mihomo/`; it only survives as a fallback path when
  looking up an existing `.deploy_config`)
- Binary: `/usr/local/bin/mihomo`
- Service: `/etc/systemd/system/mihomo.service`

### AdGuardHome Integration
When enabled, AdGuardHome IP is set as upstream DNS:
```yaml
nameserver:
  - 192.168.1.x  # AdGuardHome IP
  - 192.168.1.1  # Fallback gateway
```

## Deployment Patterns

### Docker Mode
- Uses `metacubex/mihomo:latest` image by default
- Creates container named `mihomo` with `--restart=always`
- **Runs on a dedicated `macvlan` network** (`mihomo-macvlan`), not `net=host`:
  `docker network create -d macvlan --subnet=$LAN_SUBNET --gateway=$LAN_GW -o parent=$PARENT_IF`,
  and the container is started with `--ip=$MIHOMO_IP` so it holds a real LAN IP that
  clients can ARP for directly (required for a bypass gateway).
  Known side effect: with macvlan the **Docker host itself cannot reach that IP**,
  so the dashboard has to be opened from another machine.
- Mounts config directory to `/root/.config/mihomo`
- TUN via `--device=/dev/net/tun` + `--cap-add=NET_ADMIN` — **not** `privileged` mode
- `--sysctl net.ipv4.ip_forward=1` and `--sysctl net.ipv4.conf.all.src_valid_mark=1`
- `--ulimit nofile=1048576:1048576` + `--log-opt max-size=10m` + `--log-opt max-file=3`.
  ⚠️ These two must be passed **again** when recreating the container in
  `update_mihomo_docker()`: `docker_collect_preserved_run_args()` does not collect
  ulimit/log-opt, so they would be silently dropped after `--update`.

### Binary Mode
- Downloads latest release from GitHub
- Creates systemd service at `/etc/systemd/system/mihomo.service`
- Enables `ip_forward` and `src_valid_mark` sysctl
- Service managed via `systemctl start/stop/restart mihomo`

## Country/Region Detection

The script automatically detects node countries from subscription names using:

**Keywords** (lines 1047-1067): Chinese names (香港, 台湾, 日本), English names (HK, TW, JP), Emoji flags (🇭🇰, 🇹🇼, 🇯🇵)

**Detection** (`detect_countries_from_subscription()`): Downloads subscription, parses YAML, extracts names, matches keywords

**Generation** (`generate_country_proxy_groups()`): Creates policy groups for detected countries with manual/auto/relay selectors

## Error Handling

The script uses strict mode (`set -euo pipefail`) and comprehensive error handling:

- `error_exit()`: Logs error and exits with cleanup
- `run_cmd()`: Executes commands with safety checks
- `run_with_retry()`: Retries network operations (default 3 attempts)
- All operations log to both console and `/var/log/mihomo/deploy-*.log`

## Platform Detection

Special handling for **Synology DSM**:
- Default config dir: `/volume1/docker/mihomo/`
- Skips timezone mounting (known issue)
- Checks for `syno_community` variable

## Common Patterns

### Downloading with Retry
```bash
download_file "$url" "$local_path" "$mode"
```
- Wraps GitHub URLs with proxy if enabled
- Retries up to `MAX_RETRIES` times
- Validates file integrity

### Safe Command Execution
```bash
run_cmd "mkdir -p '$dir1' '$dir2'"
```
- Variables wrapped in single quotes, then double quotes
- Prevents command injection through shell expansion

### Prompting with Validation
```bash
VAR="$(prompt "Display Name" "${default_value}" "validate_function")"
```
- Shows prompt with default
- Validates input using specified function
- Retries on invalid input

## Testing Notes

No automated test suite exists. Manual testing:

1. **Dry-run mode**: `--dry-run` flag shows what would be done
2. **Health checks**: Post-deployment `health_check()` verifies:
   - Service/container running
   - Config valid YAML
   - Subscription URL accessible
   - API endpoint responsive
3. **Manual verification**: Point client gateway/DNS to Mihomo IP, test browsing
