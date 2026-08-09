// Remote-side WhatsApp responder (second account, UNMEASURED — runs on
// the default network, not the captured wa-bench bridge).
//
// Fully autonomous: each incoming bench-tagged message tells it (via the
// "T<total>" token and scenario name) whether and how often to reply.
// Replies quote the message they answer, are paced >= 2s apart
// (ban-risk mitigation), and reuse the standard 120-byte body format.
//
//   GET /pair, GET /status on :3998 for one-time QR pairing.
'use strict';

const http = require('http');
const qrcode = require('qrcode-terminal');
const { makeClient, msgBody, parseTag, senderIndex, initializeWithRetry } = require('./lib');

const PORT = parseInt(process.env.WA_CONTROL_PORT || '3998', 10);
const SESSION_DIR = process.env.WA_SESSION_DIR || '/session';
const PACE_MS = parseInt(process.env.WA_PACE_MS || '2000', 10);

let state = 'starting';
let lastQR = null;

const client = makeClient(SESSION_DIR, 'bench-responder');

client.on('qr', (qr) => {
  state = 'needs-pairing';
  lastQR = qr;
  qrcode.generate(qr, { small: true });
});
client.on('ready', () => { state = 'ready'; lastQR = null; console.log('responder ready'); });
client.on('disconnected', (r) => { state = `disconnected: ${r}`; });

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

client.on('message', async (msg) => {
  const tag = parseTag(msg.body);
  if (!tag) return;                        // not a bench message
  try {
    if (tag.branch && tag.n === 1) {
      // Branch: every remaining message is a separate reply to msg 1.
      for (let n = 2; n <= tag.total; n++) {
        await sleep(PACE_MS);
        await msg.reply(msgBody(tag.scenario, tag.rep, n, tag.total));
      }
      return;
    }
    // Reply for every consecutive remote turn following message n.
    // reply() may return a broken object on some WhatsApp Web builds —
    // fall back to chaining against the original incoming message
    // (quote semantics compromise; body sizes unaffected).
    let prev = msg;
    for (let n = tag.n + 1; n <= tag.total
         && senderIndex(n, tag.participants, tag.branch) !== 1; n++) {
      await sleep(PACE_MS);
      const sentMsg = await prev.reply(msgBody(tag.scenario, tag.rep, n, tag.total));
      if (sentMsg && typeof sentMsg.reply === 'function') prev = sentMsg;
    }
  } catch (err) {
    console.error('responder error:', err);
  }
});

http.createServer((req, res) => {
  if (req.url === '/status') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    return res.end(JSON.stringify({ state }));
  }
  res.writeHead(200, { 'Content-Type': 'text/plain' });
  res.end(state === 'ready' ? 'ready' : (lastQR || 'no QR yet — wait'));
}).listen(PORT, () => console.log(`responder api on :${PORT}`));

initializeWithRetry(client, 'responder', SESSION_DIR, 'bench-responder');
