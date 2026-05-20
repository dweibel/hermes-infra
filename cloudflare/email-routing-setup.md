# Cloudflare Email Routing Setup

Configuration required for Hermes to receive inbound emails at `agent@dirkweibel.dev`.

## Prerequisites

- Domain `dirkweibel.dev` managed by Cloudflare DNS
- Cloudflare Email Routing enabled for the domain
- Email Worker deployed (`hermes-email-worker`)

## DNS Records

Add these records in Cloudflare DNS (most are auto-configured when Email Routing is enabled):

| Type | Name | Content | Priority |
|------|------|---------|----------|
| MX | dirkweibel.dev | `route1.mx.cloudflare.net` | 69 |
| MX | dirkweibel.dev | `route2.mx.cloudflare.net` | 4 |
| MX | dirkweibel.dev | `route3.mx.cloudflare.net` | 84 |
| TXT | dirkweibel.dev | `v=spf1 include:_spf.mx.cloudflare.net ~all` | — |
| TXT | _dmarc.dirkweibel.dev | `v=DMARC1; p=none; rua=mailto:dirk.weibel@gmail.com` | — |

Cloudflare typically adds the MX and SPF records automatically when you enable Email Routing. Verify they exist in the DNS tab.

## Email Routing Rule

Configure in Cloudflare Dashboard:

1. Go to **Email** → **Email Routing** → **Routing Rules**
2. Click **Custom addresses** → **Create address**
3. Set:
   - **Custom address:** `agent`
   - **Action:** Send to a Worker
   - **Destination:** `hermes-email-worker`
4. Save

This routes all mail to `agent@dirkweibel.dev` through the Email Worker, which extracts the content and POSTs it to the Hermes webhook gateway.

## Worker Secret

The worker needs the webhook passphrase to authenticate with Hermes:

```bash
cd cloudflare/email-worker
wrangler secret put WEBHOOK_PASSPHRASE
# Enter the same value as WEBHOOK_PASSPHRASE in /mnt/workspace/hermes/.env
```

## Verification

Send a test email to `agent@dirkweibel.dev` and check:

1. Worker logs: `wrangler tail hermes-email-worker`
2. Hermes logs: `podman logs -f hermes-agent`
3. Expect a reply within 60 seconds if the full pipeline is working

## Troubleshooting

- **Email bounces:** Check MX records are pointing to Cloudflare
- **Worker errors:** Run `wrangler tail` to see real-time logs
- **Webhook 401:** Verify WEBHOOK_PASSPHRASE matches between worker secret and Hermes .env
- **Webhook unreachable:** Verify port 8082 is open in both VCN security list and instance firewall
- **No reply:** Check Hermes has the `cloudflare-tools` MCP connection configured with valid CF_API_TOKEN
