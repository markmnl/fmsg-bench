// Measured-side WhatsApp client with an HTTP control API, driven by
// driver.sh so the orchestration stays in bash. Runs inside the
// wa-bench container; all its WhatsApp traffic crosses that bridge.
//
//   GET  /status                    -> {state}
//   GET  /pair                      -> QR string while pairing, "ready" after
//   POST /send    {to, body, mediaPath, asDocument, quoteId} -> {id}
//   POST /forward {msgId, to}       -> {id}
//   GET  /ack/<id>                  -> {ack}   (2 = delivered)
//   GET  /received?prefix=X         -> [{id, body, from, ts}]
//
// The control port itself is excluded from capture by filter.
'use strict';

const fs = require('fs');
const http = require('http');
const { MessageMedia } = require('whatsapp-web.js');
const qrcode = require('qrcode-terminal');
const { makeClient, initializeWithRetry } = require('./lib');

const PORT = parseInt(process.env.WA_CONTROL_PORT || '3999', 10);
const SESSION_DIR = process.env.WA_SESSION_DIR || '/session';

let state = 'starting';
let lastQR = null;
// Message ids are null on some WhatsApp Web builds, so everything is
// tracked by body text and live Message OBJECTS, never ids.
const received = [];          // recent incoming: {body, from, ts, obj}
const sent = [];              // own outgoing:    {body, to, ts, ack, obj}

const client = makeClient(SESSION_DIR, 'bench-bot');

client.on('qr', (qr) => {
  state = 'needs-pairing';
  lastQR = qr;
  qrcode.generate(qr, { small: true });
});
client.on('ready', () => { state = 'ready'; lastQR = null; console.log('bot ready'); });
client.on('disconnected', (r) => { state = `disconnected: ${r}`; });
client.on('message', (msg) => {
  received.push({ body: msg.body || '', from: msg.from, ts: Date.now(), obj: msg });
  if (received.length > 100) received.shift();
});
client.on('message_create', (msg) => {
  if (!msg.fromMe) return;
  sent.push({ body: msg.body || '', to: msg.to, ts: Date.now(), ack: 0, obj: msg });
  if (sent.length > 100) sent.shift();
});
client.on('message_ack', (msg, ack) => {
  // Ids are unreliable; attribute the ack to the newest own message
  // with the same body.
  const body = msg.body || '';
  for (let i = sent.length - 1; i >= 0; i--) {
    if (sent[i].body === body) {
      sent[i].ack = Math.max(sent[i].ack, ack);
      return;
    }
  }
});

const strip = ({ body, from, to, ts, ack }) => ({ body, from, to, ts, ack });

function findByPrefix(list, prefix) {
  for (let i = list.length - 1; i >= 0; i--) {
    if (list[i].body.startsWith(prefix)) return list[i];
  }
  return null;
}

function json(res, code, obj) {
  res.writeHead(code, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify(obj));
}

async function readBody(req) {
  const chunks = [];
  for await (const c of req) chunks.push(c);
  return JSON.parse(Buffer.concat(chunks).toString() || '{}');
}

const server = http.createServer(async (req, res) => {
  try {
    const url = new URL(req.url, 'http://x');
    if (req.method === 'GET' && url.pathname === '/status') {
      return json(res, 200, { state });
    }
    if (req.method === 'GET' && url.pathname === '/pair') {
      res.writeHead(200, { 'Content-Type': 'text/plain' });
      return res.end(state === 'ready' ? 'ready' : (lastQR || 'no QR yet — wait'));
    }
    if (req.method === 'GET' && url.pathname === '/received') {
      const prefix = url.searchParams.get('prefix') || '';
      return json(res, 200, received.filter((m) => m.body.startsWith(prefix)).map(strip));
    }
    if (req.method === 'GET' && url.pathname === '/sent') {
      const prefix = url.searchParams.get('prefix') || '';
      return json(res, 200, sent.filter((m) => m.body.startsWith(prefix)).map(strip));
    }
    if (req.method === 'POST' && url.pathname === '/send') {
      const { to, body, mediaPath, asDocument, quotePrefix } = await readBody(req);
      const opts = {};
      let content = body;
      if (mediaPath) {
        content = MessageMedia.fromFilePath(mediaPath);
        if (body) opts.caption = body;
        if (asDocument) opts.sendMediaAsDocument = true;
      }
      try {
        if (quotePrefix) {
          // Reply via the received message OBJECT (ids are unreliable).
          const target = findByPrefix(received, quotePrefix);
          if (!target) return json(res, 404, { error: 'quote target not found' });
          await target.obj.reply(content, undefined, opts);
        } else {
          await client.sendMessage(to, content, opts);
        }
      } catch (err) {
        // Some builds throw AFTER the message is actually sent; the
        // driver confirms via /sent acks, so report and continue.
        console.error('send: post-send error (message may still be out):', err.message);
      }
      return json(res, 200, { ok: true });
    }
    if (req.method === 'POST' && url.pathname === '/forward') {
      const { prefix, to } = await readBody(req);
      const entry = findByPrefix(sent, prefix);
      if (!entry) return json(res, 404, { error: 'sent message not found' });
      // forward() accepts a chat-id string — getChatById is broken on
      // some WhatsApp Web builds, so never look the chat up.
      await entry.obj.forward(to);
      return json(res, 200, { forwarded: true });
    }
    json(res, 404, { error: 'not found' });
  } catch (err) {
    json(res, 500, { error: String(err) });
  }
});

server.listen(PORT, () => console.log(`control api on :${PORT}`));
initializeWithRetry(client, 'bot', SESSION_DIR, 'bench-bot');
