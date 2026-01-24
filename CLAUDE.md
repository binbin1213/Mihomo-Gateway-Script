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
| `deploy-mihomo-optimized.sh` | Main deployment script with all functionality | ~3350 |
| `config.yaml.tpl` | Basic configuration template | Simple proxy groups |
| `config-region.yaml.tpl` | Region-grouped configuration template | Country-based proxy groups |
| `README.md` | User documentation (Chinese) | Deployment guide and usage |

## Script Architecture

The script is organized into functional sections (marked by comment blocks):

### Core Sections
1. **Global Variables** (lines 11-44) - Configuration, logging, retry settings
2. **Utility Functions** (49-200) - Logging, command execution, cleanup, error handling
3. **Input Validation** (206-355) - IP, CIDR, URL, interface names, path sanitization
4. **Interactive Input** (359-548) - User prompts with validation, URL sanitization
5. **File Operations** (552-716) - Temp directory, download with retry, checksum verification, ZIP extraction
6. **GitHub/Proxy** (720-761) - GitHub proxy wrapping for resource downloads
7. **Configuration Management** (765-945) - Backup, validation, load/save (JSON/Shell formats)
8. **Platform Detection** (949-961) - OS and architecture detection
9. **Network Detection** (987-1040) - Auto-detect physical interface, gateway, subnet
10. **Country Detection** (1044-1191) - Parse subscription to detect nodes by country/region
11. **Template Rendering** (1195-1384) - Render config templates with AWK functions
12. **Dependency Checks** (1388-1432) - Verify required commands available
13. **Parameter Collection** (1481-1635) - Interactive deployment wizard
14. **Dashboard Installation** (1639-1710) - Install metacubexd/zashboard UI
15. **DNS/Rules Generation** (1714-1865) - Generate DNS and routing rules
16. **Deployment Functions** (1869-1920) - Docker mode deployment
17. **Binary Deployment** (1924-2149) - Binary mode with systemd service
18. **Health Check** (2153-2224) - Post-deployment validation
19. **Auto-Update** (2228-2355) - Cron-based Mihomo updates
20. **Uninstall** (2359-2497) - Complete cleanup
21. **CLI Actions** (2501-2943) - Update, subscription change, menu system
22. **Main Entry** (3067-3349) - Argument parsing, action routing

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
- Config: `/etc/mihomo/config.yaml`
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
- Creates container named `mihomo`
- Mounts config directory as volume
- Sets `net=host` for transparent proxy
- Configures `privileged` mode for TUN

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
