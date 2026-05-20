/**
 * Cloudflare Email Worker — receives inbound emails and forwards them
 * to the Hermes webhook gateway on the OCI instance.
 *
 * Email Routing rule: agent@dirkweibel.dev → this worker
 * Webhook target: http://<OCI_SERVER_IP>:8082/webhooks/email
 *
 * Authentication: HMAC-SHA256 signature in X-Webhook-Signature header.
 * The Hermes webhook platform validates this against the route's secret.
 */

export interface Env {
  WEBHOOK_PASSPHRASE: string;
  OCI_SERVER_IP: string;
}

interface WebhookPayload {
  sender: string;
  topic: string;
  content: string;
  event_type: string;
}

/**
 * Compute HMAC-SHA256 hex digest of the body using the shared secret.
 */
async function computeHmac(secret: string, body: string): Promise<string> {
  const encoder = new TextEncoder();
  const key = await crypto.subtle.importKey(
    "raw",
    encoder.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"]
  );
  const signature = await crypto.subtle.sign(
    "HMAC",
    key,
    encoder.encode(body)
  );
  return Array.from(new Uint8Array(signature))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

/**
 * Extract plain text body from a raw email message.
 * Handles simple single-part messages. For multipart MIME, extracts
 * the text after the headers boundary.
 */
function extractPlainText(raw: string): string {
  // Find the end of headers (double CRLF or double LF)
  const crlfEnd = raw.indexOf("\r\n\r\n");
  const lfEnd = raw.indexOf("\n\n");
  const headerEnd = crlfEnd !== -1 ? crlfEnd + 4 : lfEnd !== -1 ? lfEnd + 2 : -1;

  if (headerEnd === -1) {
    return raw.trim();
  }

  const body = raw.slice(headerEnd);

  // Check if it's multipart
  const contentTypeMatch = raw
    .slice(0, headerEnd)
    .match(/Content-Type:\s*multipart\/\w+;\s*boundary="?([^"\r\n]+)"?/i);

  if (!contentTypeMatch) {
    // Simple single-part message
    return body.trim();
  }

  // Multipart: find the text/plain part
  const boundary = contentTypeMatch[1];
  const parts = body.split(`--${boundary}`);

  for (const part of parts) {
    if (part.match(/Content-Type:\s*text\/plain/i)) {
      const partHeaderEnd = part.indexOf("\r\n\r\n") !== -1
        ? part.indexOf("\r\n\r\n") + 4
        : part.indexOf("\n\n") + 2;
      if (partHeaderEnd > 0) {
        return part.slice(partHeaderEnd).trim();
      }
    }
  }

  // Fallback: return the raw body
  return body.trim();
}

export default {
  async email(
    message: ForgeEmailMessage,
    env: Env
  ): Promise<void> {
    const sender = message.from;
    const topic = message.headers.get("subject") || "(no subject)";

    let content: string;
    try {
      const rawText = await new Response(message.raw).text();
      content = extractPlainText(rawText);
    } catch (err) {
      console.error("Failed to extract email body:", err);
      message.setReject("Failed to parse email body");
      return;
    }

    const payload: WebhookPayload = {
      sender,
      topic,
      content,
      event_type: "email",
    };

    const body = JSON.stringify(payload);
    const signature = await computeHmac(env.WEBHOOK_PASSPHRASE, body);
    const webhookUrl = `http://${env.OCI_SERVER_IP}:8082/webhooks/email`;

    try {
      const response = await fetch(webhookUrl, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "X-Webhook-Signature": signature,
        },
        body,
      });

      if (!response.ok) {
        const text = await response.text();
        console.error(`Webhook returned ${response.status}: ${text}`);
        message.setReject(
          `Webhook rejected with status ${response.status}`
        );
        return;
      }

      console.log(`Email from ${sender} forwarded successfully`);
    } catch (err) {
      console.error("Failed to reach webhook:", err);
      message.setReject("Webhook unreachable");
    }
  },
};

/**
 * Minimal type definitions for Cloudflare Email Workers.
 */
interface ForgeEmailMessage {
  from: string;
  to: string;
  headers: Headers;
  raw: ReadableStream;
  rawSize: number;
  setReject(reason: string): void;
}
