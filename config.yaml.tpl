# Mihomo 配置文件 - 优化版本
# 生成时间：自动生成
# 注意：此文件由 deploy-mihomo.sh 脚本生成，请勿手动编辑

# =============================================================================
# GeoX 数据库配置
# =============================================================================
geodata-mode: true
geox-url:
  geoip: "https://ghfast.top/https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geoip.dat"
  geosite: "https://ghfast.top/https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geosite.dat"
  mmdb: "https://ghfast.top/https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/country.mmdb"

# =============================================================================
# 基础配置
# =============================================================================
mixed-port: 7890
allow-lan: true
bind-address: "*"  # 允许所有接口绑定
mode: rule
log-level: info
ipv6: false  # 禁用 IPv6（可选，根据网络环境调整）

# 外部控制接口
external-controller: 0.0.0.0:19090
secret: "{{CLASH_SECRET}}"

# =============================================================================
# DNS 配置
# =============================================================================

{{DNS_CONFIG}}

# =============================================================================
# 流量嗅探（Sniffer）
# =============================================================================
# 用于处理 DNS 污染和 TLS SNI，确保正确的域名解析

sniffer:
  enable: true
  parse-pure-ip: true
  override-destination: false  # 不覆盖目标地址，更安全
  sniff:
    TLS:
      ports: [443, 8443]
      skip-cert-verify: false  # 验证证书，更安全
    HTTP:
      ports: [80, 8080-8880, 8888]
    QUIC:
      ports: [443, 8443]
  force-domain:
    - +.google.com
    - +.facebook.com
    - +.youtube.com
    - +.github.com
    - +.openai.com
    - +.anthropic.com

# =============================================================================
# UI 面板配置
# =============================================================================

{{UI_CONFIG}}

# =============================================================================
# TUN 模式配置（透明代理核心）
# =============================================================================
tun:
  enable: true
  stack: system  # 使用系统栈，兼容性更好
  auto-route: true
  auto-detect-interface: true
  dns-hijack:
    - any:53
    - tcp://any:53  # 劫持 TCP DNS 请求
  strict-route: true  # 严格路由，防止流量泄露

# =============================================================================
# 代理提供者（Proxy Provider）
# =============================================================================
# 从订阅链接自动获取节点列表

proxy-providers:
  sub:
    type: http
    url: "{{SUB_URL}}"
    interval: 3600  # 每小时更新一次
    path: ./proxy_providers/sub.yaml
    proxy: DIRECT
    health-check:
      enable: true
      url: http://www.gstatic.com/generate_204
      interval: 600  # 每 10 分钟检查一次节点健康状态

# =============================================================================
# 策略组（Proxy Groups）
# =============================================================================

proxy-groups:
  # 主策略组 - 手动选择
  - name: 所有-手选
    type: select
    use:
      - sub
    filter: "^((?!(DIRECT|REJECT)).)*$"

  # 自动测速策略组 - URL 测试
  - name: 所有-自动
    type: url-test
    use:
      - sub
    url: "https://cp.cloudflare.com/generate_204"
    interval: 300
    tolerance: 50  # 延迟容忍度（毫秒）
    filter: "^((?!(DIRECT|REJECT)).)*$"

  # 故障转移策略组 - Fallback
  - name: 所有-故转
    type: fallback
    use:
      - sub
    url: "https://cp.cloudflare.com/generate_204"
    interval: 300
    filter: "^((?!(DIRECT|REJECT)).)*$"

  # Smart 策略组（可选）
{{SMART_GROUP_BLOCK}}

  # ChatGPT 专用策略组
  - name: ChatGPT
    type: select
    proxies:
      {{SMART_PROXY_LINE}}
      - 所有-自动
      - 所有-故转
      - 所有-手选
      - DIRECT
      - REJECT

  # Claude 专用策略组
  - name: Claude
    type: select
    proxies:
      {{SMART_PROXY_LINE}}
      - 所有-自动
      - 所有-故转
      - 所有-手选
      - DIRECT
      - REJECT

  # GitHub 专用策略组
  - name: GitHub
    type: select
    proxies:
      {{SMART_PROXY_LINE}}
      - 所有-自动
      - 所有-故转
      - 所有-手选
      - DIRECT
      - REJECT

  # Telegram 专用策略组
  - name: Telegram
    type: select
    proxies:
      {{SMART_PROXY_LINE}}
      - 所有-自动
      - 所有-故转
      - 所有-手选
      - DIRECT
      - REJECT

  # Netflix 专用策略组
  - name: Netflix
    type: select
    proxies:
      {{SMART_PROXY_LINE}}
      - 所有-自动
      - 所有-故转
      - 所有-手选
      - DIRECT
      - REJECT

  # Google 专用策略组
  - name: Google
    type: select
    proxies:
      {{SMART_PROXY_LINE}}
      - 所有-自动
      - 所有-故转
      - 所有-手选
      - DIRECT
      - REJECT

  # Apple 专用策略组
  - name: Apple
    type: select
    proxies:
      - DIRECT  # 优先直连
      {{SMART_PROXY_LINE}}
      - 所有-自动
      - 所有-故转
      - 所有-手选
      - REJECT

  # Microsoft 专用策略组
  - name: Microsoft
    type: select
    proxies:
      - DIRECT  # 优先直连
      {{SMART_PROXY_LINE}}
      - 所有-自动
      - 所有-故转
      - 所有-手选
      - REJECT

  # Steam 专用策略组
  - name: Steam
    type: select
    proxies:
      - DIRECT  # 优先直连
      {{SMART_PROXY_LINE}}
      - 所有-自动
      - 所有-故转
      - 所有-手选
      - REJECT

  # 广告拦截策略组
  - name: Block
    type: select
    proxies:
      - REJECT
      - DIRECT

  # 国内网站策略组
  - name: 国内
    type: select
    proxies:
      - DIRECT
      {{SMART_PROXY_LINE}}
      - 所有-自动
      - 所有-故转
      - 所有-手选

  # 国外网站策略组
  - name: 国外
    type: select
    proxies:
      {{SMART_PROXY_LINE}}
      - 所有-自动
      - 所有-故转
      - 所有-手选
      - DIRECT

  # 其他流量策略组
  - name: 其他
    type: select
    proxies:
      - 国外
      - 国内
      - DIRECT

# =============================================================================
# 规则提供者（Rule Provider）
# =============================================================================
# 自动下载和更新分流规则

rule-providers:
  # OpenAI 相关域名
  openai:
    type: http
    interval: 86400  # 每天更新
    behavior: domain
    format: mrs
    path: ./ruleset/openai.mrs
    url: "{{URL_RULESET_OPENAI}}"

  # Claude 相关域名
  claude:
    type: http
    interval: 86400
    behavior: classical
    format: text
    path: ./ruleset/claude.list
    url: "{{URL_RULESET_CLAUDE}}"

  # GitHub 相关域名
  github:
    type: http
    interval: 86400
    behavior: domain
    format: mrs
    path: ./ruleset/github.mrs
    url: "{{URL_RULESET_GITHUB}}"

  # Telegram 域名规则
  telegram_domain:
    type: http
    interval: 86400
    behavior: domain
    format: mrs
    path: ./ruleset/telegram_domain.mrs
    url: "{{URL_RULESET_TELEGRAM_DOMAIN}}"

  # Telegram IP 规则
  telegram_ip:
    type: http
    interval: 86400
    behavior: ipcidr
    format: mrs
    path: ./ruleset/telegram_ip.mrs
    url: "{{URL_RULESET_TELEGRAM_IP}}"

  # Netflix 域名规则
  netflix_domain:
    type: http
    interval: 86400
    behavior: domain
    format: mrs
    path: ./ruleset/netflix_domain.mrs
    url: "{{URL_RULESET_NETFLIX_DOMAIN}}"

  # Netflix IP 规则
  netflix_ip:
    type: http
    interval: 86400
    behavior: ipcidr
    format: mrs
    path: ./ruleset/netflix_ip.mrs
    url: "{{URL_RULESET_NETFLIX_IP}}"

  # Google 域名规则
  google_domain:
    type: http
    interval: 86400
    behavior: domain
    format: mrs
    path: ./ruleset/google_domain.mrs
    url: "{{URL_RULESET_GOOGLE_DOMAIN}}"

  # Google IP 规则
  google_ip:
    type: http
    interval: 86400
    behavior: ipcidr
    format: mrs
    path: ./ruleset/google_ip.mrs
    url: "{{URL_RULESET_GOOGLE_IP}}"

  # Apple 域名规则
  apple:
    type: http
    interval: 86400
    behavior: domain
    format: mrs
    path: ./ruleset/apple.mrs
    url: "{{URL_RULESET_APPLE}}"

  # Apple 中国域名规则
  apple_cn:
    type: http
    interval: 86400
    behavior: domain
    format: mrs
    path: ./ruleset/apple_cn.mrs
    url: "{{URL_RULESET_APPLE_CN}}"

  # Microsoft 域名规则
  microsoft:
    type: http
    interval: 86400
    behavior: domain
    format: mrs
    path: ./ruleset/microsoft.mrs
    url: "{{URL_RULESET_MICROSOFT}}"

  # Steam 域名规则
  steam:
    type: http
    interval: 86400
    behavior: domain
    format: mrs
    path: ./ruleset/steam.mrs
    url: "{{URL_RULESET_STEAM}}"

  # 中国域名规则
  china_domain:
    type: http
    interval: 86400
    behavior: domain
    format: mrs
    path: ./ruleset/china_domain.mrs
    url: "{{URL_RULESET_CHINA_DOMAIN}}"

  # 中国 IP 规则
  china_ip:
    type: http
    interval: 86400
    behavior: ipcidr
    format: mrs
    path: ./ruleset/china_ip.mrs
    url: "{{URL_RULESET_CHINA_IP}}"

  # 私有地址规则
  private:
    type: http
    interval: 86400
    behavior: domain
    format: mrs
    path: ./ruleset/private.mrs
    url: "{{URL_RULESET_PRIVATE}}"

  # 广告拦截规则
  block:
    type: http
    interval: 86400
    behavior: classical
    format: text
    path: ./ruleset/block.list
    url: "{{URL_RULESET_BLOCK}}"

# =============================================================================
# 分流规则（Rules）
# =============================================================================
# 按优先级从高到低匹配

rules:
  # 局域网流量 - 直连
  - IP-CIDR,{{LAN_SUBNET}},DIRECT,no-resolve
  - IP-CIDR,{{MIHOMO_IP}}/32,DIRECT,no-resolve
  - IP-CIDR,{{LAN_GW}}/32,DIRECT,no-resolve

  # AdGuard Home（如果使用）
  {{ADGUARD_RULE_LINE}}

  # 禁止 DNS over HTTPS/TLS 端口（防止 DNS 泄漏）
  - DST-PORT,853,REJECT
  - DST-PORT,784,REJECT
  - DST-PORT,8853,REJECT
  - DST-PORT,5443,REJECT

  # 禁止公共 DNS 服务（防止 DNS 泄漏）
  - DOMAIN,dns.google,REJECT
  - DOMAIN-SUFFIX,cloudflare-dns.com,REJECT
  - DOMAIN,mozilla.cloudflare-dns.com,REJECT
  - DOMAIN,dns.quad9.net,REJECT
  - DOMAIN,doh.opendns.com,REJECT
  - DOMAIN-SUFFIX,nextdns.io,REJECT
  - DOMAIN,dns.adguard.com,REJECT
  - DOMAIN,dns-family.adguard.com,REJECT
  - DOMAIN,dns-unfiltered.adguard.com,REJECT
  - DOMAIN-SUFFIX,cleanbrowsing.org,REJECT

  # 广告拦截
  - RULE-SET,block,Block

  # AI 服务
  - RULE-SET,openai,ChatGPT
  - RULE-SET,claude,Claude

  # 开发者服务
  - RULE-SET,github,GitHub

  # 即时通讯
  - RULE-SET,telegram_domain,Telegram
  - RULE-SET,telegram_ip,Telegram,no-resolve

  # 流媒体
  - RULE-SET,netflix_domain,Netflix
  - RULE-SET,netflix_ip,Netflix,no-resolve

  # 搜索引擎
  - RULE-SET,google_domain,Google
  - RULE-SET,google_ip,Google,no-resolve

  # 系统服务
  - RULE-SET,apple_cn,Apple
  - RULE-SET,apple,Apple
  - RULE-SET,microsoft,Microsoft
  - RULE-SET,steam,Steam

  # 国内服务
  - RULE-SET,private,国内
  - RULE-SET,china_domain,国内
  - RULE-SET,china_ip,国内,no-resolve

  # 其他流量
  - MATCH,其他

# =============================================================================
# 性能优化配置
# =============================================================================

# 缓存配置（可选）
#profile:
#  store-selected: true  # 记住选择的节点
#  store-fake-ip: true    # 缓存 Fake-IP

# 实验性功能（可选）
#experimental:
#  hosts:
#    'example.com': '1.2.3.4'
