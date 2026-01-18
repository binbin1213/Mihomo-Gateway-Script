# ========================
# Clash-ALL 地区分组优化配置
# 生成时间：自动生成
# 注意：此文件由 deploy-mihomo.sh 脚本生成，请勿手动编辑
# ========================

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
bind-address: "*"
mode: rule
log-level: info
ipv6: false

# 外部控制接口
external-controller: 0.0.0.0:{{EXTERNAL_PORT}}
secret: "{{CLASH_SECRET}}"

# =============================================================================
# DNS 配置
# =============================================================================

{{DNS_CONFIG}}

# =============================================================================
# 流量嗅探（Sniffer）
# =============================================================================
sniffer:
  enable: true
  parse-pure-ip: true
  override-destination: false
  sniff:
    TLS:
      ports: [443, 8443]
      skip-cert-verify: false
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
  stack: system
  auto-route: true
  auto-detect-interface: true
  dns-hijack:
    - any:53
    - tcp://any:53
  strict-route: true

# =============================================================================
# 代理提供者（Proxy Provider）
# =============================================================================
proxy-providers:
  sub:
    type: http
    url: "{{SUB_URL}}"
    interval: 3600
    path: ./proxy_providers/sub.yaml
    proxy: DIRECT
    health-check:
      enable: true
      url: http://www.gstatic.com/generate_204
      interval: 600

# 内置代理
proxies:
  - {name: 直连, type: direct}
  - {name: 拒绝, type: reject}

# =============================================================================
# 策略组（Proxy Groups）
# =============================================================================

proxy-groups:
  # Smart 策略组（可选）
{{SMART_GROUP_BLOCK}}

  # 业务分流组 - 默认策略（代理优先）
  - name: ChatGPT
    type: select
    proxies:
      {{SMART_PROXY_LINE}}
      - 所有-智选
{{COUNTRY_PROXIES_LIST}}
      - 直连
      - 拒绝

  - name: Claude
    type: select
    proxies:
      {{SMART_PROXY_LINE}}
      - 所有-智选
{{COUNTRY_PROXIES_LIST}}
      - 直连
      - 拒绝

  - name: Gemini
    type: select
    proxies:
      {{SMART_PROXY_LINE}}
      - 所有-智选
{{COUNTRY_PROXIES_LIST}}
      - 直连
      - 拒绝

  - name: Copilot
    type: select
    proxies:
      {{SMART_PROXY_LINE}}
      - 所有-智选
{{COUNTRY_PROXIES_LIST}}
      - 直连
      - 拒绝

  - name: Perplexity
    type: select
    proxies:
      {{SMART_PROXY_LINE}}
      - 所有-智选
{{COUNTRY_PROXIES_LIST}}
      - 直连
      - 拒绝

  - name: Meta AI
    type: select
    proxies:
      {{SMART_PROXY_LINE}}
      - 所有-智选
{{COUNTRY_PROXIES_LIST}}
      - 直连
      - 拒绝

  - name: GitHub
    type: select
    proxies:
      {{SMART_PROXY_LINE}}
      - 所有-智选
{{COUNTRY_PROXIES_LIST}}
      - 直连
      - 拒绝

  - name: Reddit
    type: select
    proxies:
      {{SMART_PROXY_LINE}}
      - 所有-智选
{{COUNTRY_PROXIES_LIST}}
      - 直连
      - 拒绝

  - name: Telegram
    type: select
    proxies:
      {{SMART_PROXY_LINE}}
      - 所有-智选
{{COUNTRY_PROXIES_LIST}}
      - 直连
      - 拒绝

  - name: WhatsApp
    type: select
    proxies:
      {{SMART_PROXY_LINE}}
      - 所有-智选
{{COUNTRY_PROXIES_LIST}}
      - 直连
      - 拒绝

  - name: Facebook
    type: select
    proxies:
      {{SMART_PROXY_LINE}}
      - 所有-智选
{{COUNTRY_PROXIES_LIST}}
      - 直连
      - 拒绝

  - name: YouTube
    type: select
    proxies:
      {{SMART_PROXY_LINE}}
      - 所有-智选
{{COUNTRY_PROXIES_LIST}}
      - 直连
      - 拒绝

  - name: TikTok
    type: select
    proxies:
      {{SMART_PROXY_LINE}}
      - 所有-智选
{{COUNTRY_PROXIES_LIST}}
      - 直连
      - 拒绝

  - name: Netflix
    type: select
    proxies:
      {{SMART_PROXY_LINE}}
      - 所有-智选
{{COUNTRY_PROXIES_LIST}}
      - 直连
      - 拒绝

  - name: HBO
    type: select
    proxies:
      {{SMART_PROXY_LINE}}
      - 所有-智选
{{COUNTRY_PROXIES_LIST}}
      - 直连
      - 拒绝

  - name: Disney
    type: select
    proxies:
      {{SMART_PROXY_LINE}}
      - 所有-智选
{{COUNTRY_PROXIES_LIST}}
      - 直连
      - 拒绝

  - name: Amazon
    type: select
    proxies:
      - 直连
      {{SMART_PROXY_LINE}}
      - 所有-智选
{{COUNTRY_PROXIES_LIST}}
      - 拒绝

  - name: Crunchyroll
    type: select
    proxies:
      {{SMART_PROXY_LINE}}
      - 所有-智选
{{COUNTRY_PROXIES_LIST}}
      - 直连
      - 拒绝

  - name: Spotify
    type: select
    proxies:
      {{SMART_PROXY_LINE}}
      - 所有-智选
{{COUNTRY_PROXIES_LIST}}
      - 直连
      - 拒绝

  - name: Nvidia
    type: select
    proxies:
      {{SMART_PROXY_LINE}}
      - 所有-智选
{{COUNTRY_PROXIES_LIST}}
      - 直连
      - 拒绝

  - name: Crypto
    type: select
    proxies:
      {{SMART_PROXY_LINE}}
      - 所有-智选
{{COUNTRY_PROXIES_LIST}}
      - 直连
      - 拒绝

  - name: Google
    type: select
    proxies:
      {{SMART_PROXY_LINE}}
      - 所有-智选
{{COUNTRY_PROXIES_LIST}}
      - 直连
      - 拒绝

  - name: Test
    type: select
    proxies:
      {{SMART_PROXY_LINE}}
      - 所有-智选
{{COUNTRY_PROXIES_LIST}}
      - 直连
      - 拒绝

  - name: Block
    type: select
    proxies:
      - 拒绝
      - 直连

  - name: 国外
    type: select
    proxies:
      {{SMART_PROXY_LINE}}
      - 所有-智选
{{COUNTRY_PROXIES_LIST}}
      - 直连
      - 拒绝

  - name: 其他
    type: select
    proxies:
      - 国外
      - 国内
      - 直连

  # 直连优先组
  - name: Apple
    type: select
    proxies:
      - 直连
      {{SMART_PROXY_LINE}}
      - 所有-智选
{{COUNTRY_PROXIES_LIST}}
      - 拒绝

  - name: Microsoft
    type: select
    proxies:
      - 直连
      {{SMART_PROXY_LINE}}
      - 所有-智选
{{COUNTRY_PROXIES_LIST}}
      - 拒绝

  - name: Steam
    type: select
    proxies:
      - 直连
      {{SMART_PROXY_LINE}}
      - 所有-智选
{{COUNTRY_PROXIES_LIST}}
      - 拒绝

  - name: Games
    type: select
    proxies:
      - 直连
      {{SMART_PROXY_LINE}}
      - 所有-智选
{{COUNTRY_PROXIES_LIST}}
      - 拒绝

  - name: 国内
    type: select
    proxies:
      - 直连
      {{SMART_PROXY_LINE}}
      - 所有-智选
{{COUNTRY_PROXIES_LIST}}
      - 拒绝


  # 所有节点策略组

  - name: 所有-手选
    type: select
    use:
      - sub
    filter: "^((?!(直连|拒绝)).)*$"

  - name: 所有-自动
    type: url-test
    use:
      - sub
    url: "https://cp.cloudflare.com/generate_204"
    interval: 300
    tolerance: 50
    filter: "^((?!(直连|拒绝)).)*$"

  - name: 所有-故转
    type: fallback
    use:
      - sub
    url: "https://cp.cloudflare.com/generate_204"
    interval: 300
    filter: "^((?!(直连|拒绝)).)*$"

{{COUNTRY_PROXY_GROUPS}}

rule-providers:
  # AI 服务
  openai:
    type: http
    interval: 86400
    behavior: domain
    format: mrs
    path: ./ruleset/openai.mrs
    url: "{{URL_RULESET_OPENAI}}"

  claude:
    type: http
    interval: 86400
    behavior: classical
    format: text
    path: ./ruleset/claude.list
    url: "{{URL_RULESET_CLAUDE}}"

  perplexity:
    type: http
    interval: 86400
    behavior: domain
    format: mrs
    path: ./ruleset/perplexity.mrs
    url: "{{URL_RULESET_PERPLEXITY}}"

  copilot:
    type: http
    interval: 86400
    behavior: classical
    format: text
    path: ./ruleset/copilot.list
    url: "{{URL_RULESET_COPILOT}}"

  gemini:
    type: http
    interval: 86400
    behavior: classical
    format: text
    path: ./ruleset/gemini.list
    url: "{{URL_RULESET_GEMINI}}"

  meta_ai:
    type: http
    interval: 86400
    behavior: classical
    format: text
    path: ./ruleset/meta_ai.list
    url: "{{URL_RULESET_META_AI}}"

  # 开发者服务
  github:
    type: http
    interval: 86400
    behavior: domain
    format: mrs
    path: ./ruleset/github.mrs
    url: "{{URL_RULESET_GITHUB}}"

  reddit:
    type: http
    interval: 86400
    behavior: domain
    format: mrs
    path: ./ruleset/reddit.mrs
    url: "{{URL_RULESET_REDDIT}}"

  # 即时通讯
  telegram_domain:
    type: http
    interval: 86400
    behavior: domain
    format: mrs
    path: ./ruleset/telegram_domain.mrs
    url: "{{URL_RULESET_TELEGRAM_DOMAIN}}"

  telegram_ip:
    type: http
    interval: 86400
    behavior: ipcidr
    format: mrs
    path: ./ruleset/telegram_ip.mrs
    url: "{{URL_RULESET_TELEGRAM_IP}}"

  whatsapp:
    type: http
    interval: 86400
    behavior: classical
    format: text
    path: ./ruleset/whatsapp.list
    url: "{{URL_RULESET_WHATSAPP}}"

  facebook:
    type: http
    interval: 86400
    behavior: domain
    format: mrs
    path: ./ruleset/facebook.mrs
    url: "{{URL_RULESET_FACEBOOK}}"

  # 流媒体
  netflix_domain:
    type: http
    interval: 86400
    behavior: domain
    format: mrs
    path: ./ruleset/netflix_domain.mrs
    url: "{{URL_RULESET_NETFLIX_DOMAIN}}"

  netflix_ip:
    type: http
    interval: 86400
    behavior: ipcidr
    format: mrs
    path: ./ruleset/netflix_ip.mrs
    url: "{{URL_RULESET_NETFLIX_IP}}"

  youtube:
    type: http
    interval: 86400
    behavior: domain
    format: mrs
    path: ./ruleset/youtube.mrs
    url: "{{URL_RULESET_YOUTUBE}}"

  tiktok:
    type: http
    interval: 86400
    behavior: domain
    format: mrs
    path: ./ruleset/tiktok.mrs
    url: "{{URL_RULESET_TIKTOK}}"

  disney:
    type: http
    interval: 86400
    behavior: domain
    format: mrs
    path: ./ruleset/disney.mrs
    url: "{{URL_RULESET_DISNEY}}"

  hbo:
    type: http
    interval: 86400
    behavior: domain
    format: mrs
    path: ./ruleset/hbo.mrs
    url: "{{URL_RULESET_HBO}}"

  amazon:
    type: http
    interval: 86400
    behavior: domain
    format: mrs
    path: ./ruleset/amazon.mrs
    url: "{{URL_RULESET_AMAZON}}"

  crunchyroll:
    type: http
    interval: 86400
    behavior: classical
    format: text
    path: ./ruleset/crunchyroll.list
    url: "{{URL_RULESET_CRUNCHYROLL}}"

  spotify:
    type: http
    interval: 86400
    behavior: domain
    format: mrs
    path: ./ruleset/spotify.mrs
    url: "{{URL_RULESET_SPOTIFY}}"

  # 搜索引擎
  google_domain:
    type: http
    interval: 86400
    behavior: domain
    format: mrs
    path: ./ruleset/google_domain.mrs
    url: "{{URL_RULESET_GOOGLE_DOMAIN}}"

  google_ip:
    type: http
    interval: 86400
    behavior: ipcidr
    format: mrs
    path: ./ruleset/google_ip.mrs
    url: "{{URL_RULESET_GOOGLE_IP}}"

  # 系统服务
  apple:
    type: http
    interval: 86400
    behavior: domain
    format: mrs
    path: ./ruleset/apple.mrs
    url: "{{URL_RULESET_APPLE}}"

  apple_cn:
    type: http
    interval: 86400
    behavior: domain
    format: mrs
    path: ./ruleset/apple_cn.mrs
    url: "{{URL_RULESET_APPLE_CN}}"

  microsoft:
    type: http
    interval: 86400
    behavior: domain
    format: mrs
    path: ./ruleset/microsoft.mrs
    url: "{{URL_RULESET_MICROSOFT}}"

  steam:
    type: http
    interval: 86400
    behavior: domain
    format: mrs
    path: ./ruleset/steam.mrs
    url: "{{URL_RULESET_STEAM}}"

  # 游戏
  epic:
    type: http
    interval: 86400
    behavior: classical
    format: text
    path: ./ruleset/epic.list
    url: "{{URL_RULESET_EPIC}}"

  ea:
    type: http
    interval: 86400
    behavior: classical
    format: text
    path: ./ruleset/ea.list
    url: "{{URL_RULESET_EA}}"

  blizzard:
    type: http
    interval: 86400
    behavior: classical
    format: text
    path: ./ruleset/blizzard.list
    url: "{{URL_RULESET_BLAZZARD}}"

  ubi:
    type: http
    interval: 86400
    behavior: classical
    format: text
    path: ./ruleset/ubi.list
    url: "{{URL_RULESET_UBI}}"

  playstation:
    type: http
    interval: 86400
    behavior: classical
    format: text
    path: ./ruleset/playstation.list
    url: "{{URL_RULESET_PLAYSTATION}}"

  nintendo:
    type: http
    interval: 86400
    behavior: classical
    format: text
    path: ./ruleset/nintendo.list
    url: "{{URL_RULESET_NINTENDO}}"

  # 加密货币
  okx:
    type: http
    interval: 86400
    behavior: domain
    format: mrs
    path: ./ruleset/okx.mrs
    url: "{{URL_RULESET_OKX}}"

  bybit:
    type: http
    interval: 86400
    behavior: domain
    format: mrs
    path: ./ruleset/bybit.mrs
    url: "{{URL_RULESET_BYBIT}}"

  binance:
    type: http
    interval: 86400
    behavior: domain
    format: mrs
    path: ./ruleset/binance.mrs
    url: "{{URL_RULESET_BINANCE}}"

  # 其他
  nvidia:
    type: http
    interval: 86400
    behavior: classical
    format: text
    path: ./ruleset/nvidia.list
    url: "{{URL_RULESET_NVIDIA}}"

  china_domain:
    type: http
    interval: 86400
    behavior: domain
    format: mrs
    path: ./ruleset/china_domain.mrs
    url: "{{URL_RULESET_CHINA_DOMAIN}}"

  china_ip:
    type: http
    interval: 86400
    behavior: ipcidr
    format: mrs
    path: ./ruleset/china_ip.mrs
    url: "{{URL_RULESET_CHINA_IP}}"

  private:
    type: http
    interval: 86400
    behavior: domain
    format: mrs
    path: ./ruleset/private.mrs
    url: "{{URL_RULESET_PRIVATE}}"

  proxy:
    type: http
    interval: 86400
    behavior: classical
    format: text
    path: ./ruleset/proxy.list
    url: "{{URL_RULESET_PROXY}}"

  globe:
    type: http
    interval: 86400
    behavior: classical
    format: text
    path: ./ruleset/globe.list
    url: "{{URL_RULESET_GLOBE}}"

  direct:
    type: http
    interval: 86400
    behavior: classical
    format: text
    path: ./ruleset/direct.list
    url: "{{URL_RULESET_DIRECT}}"

  block:
    type: http
    interval: 86400
    behavior: classical
    format: text
    path: ./ruleset/block.list
    url: "{{URL_RULESET_BLOCK}}"

  test:
    type: http
    interval: 86400
    behavior: classical
    format: text
    path: ./ruleset/test.list
    url: "{{URL_RULESET_TEST}}"

# =============================================================================
# 分流规则（Rules）
# =============================================================================
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

  # 测试规则
  - RULE-SET,test,Test

  # 广告拦截
  - RULE-SET,block,Block

  # AI 服务
  - RULE-SET,openai,ChatGPT
  - RULE-SET,claude,Claude
  - RULE-SET,perplexity,Perplexity
  - RULE-SET,copilot,Copilot
  - RULE-SET,gemini,Gemini
  - RULE-SET,meta_ai,Meta AI

  # 开发者服务
  - RULE-SET,github,GitHub
  - RULE-SET,reddit,Reddit

  # 即时通讯
  - RULE-SET,telegram_domain,Telegram
  - RULE-SET,telegram_ip,Telegram,no-resolve
  - RULE-SET,whatsapp,WhatsApp
  - RULE-SET,facebook,Facebook

  # 流媒体
  - RULE-SET,youtube,YouTube
  - RULE-SET,tiktok,TikTok
  - RULE-SET,netflix_domain,Netflix
  - RULE-SET,netflix_ip,Netflix,no-resolve
  - RULE-SET,disney,Disney
  - RULE-SET,hbo,HBO
  - RULE-SET,amazon,Amazon
  - RULE-SET,crunchyroll,Crunchyroll
  - RULE-SET,spotify,Spotify

  # 搜索引擎
  - RULE-SET,google_domain,Google
  - RULE-SET,google_ip,Google,no-resolve

  # 系统服务
  - RULE-SET,apple_cn,Apple
  - RULE-SET,apple,Apple
  - RULE-SET,microsoft,Microsoft
  - RULE-SET,steam,Steam

  # 游戏
  - RULE-SET,epic,Games
  - RULE-SET,ea,Games
  - RULE-SET,blizzard,Games
  - RULE-SET,ubi,Games
  - RULE-SET,playstation,Games
  - RULE-SET,nintendo,Games

  # 加密货币
  - RULE-SET,okx,Crypto
  - RULE-SET,bybit,Crypto
  - RULE-SET,binance,Crypto

  # 其他
  - RULE-SET,nvidia,Nvidia
  - RULE-SET,proxy,国外
  - RULE-SET,globe,国外
  - RULE-SET,direct,国内
  - RULE-SET,china_domain,国内
  - RULE-SET,china_ip,国内,no-resolve
  - RULE-SET,private,国内

  # 其他流量
  - MATCH,其他

# =============================================================================
# 性能优化配置
# =============================================================================

profile:
  store-selected: true
  store-fake-ip: true
