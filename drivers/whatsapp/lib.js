// Shared helpers for the whatsapp bot/responder.
'use strict';

const fs = require('fs');
const path = require('path');
const { Client, LocalAuth } = require('whatsapp-web.js');

const BODY_SIZE = 120;

// Mirrors BODY_CORPUS in lib/common.sh — keep the two in sync.
const BODY_CORPUS = [
  'Hey, are we still on for coffee tomorrow morning before the standup?',
  'Just landed. The flight was delayed two hours but the sunset over the wing almost made up for it.',
  'Can you send me the notes from yesterday? I want to double-check the figures before the review.',
  'The garden is finally coming together. The tomatoes survived the frost after all.',
  'I tried that recipe you mentioned and somehow burnt the rice twice. Teach me your ways.',
  'Meeting moved to three. Same room, bring the printouts if you can.',
  'Saw a kingfisher by the river this morning. First one in years around here.',
  'The car is making that noise again. Booking it in for Thursday unless you need it.',
  'Finished the book you lent me. The ending was not what I expected at all.',
  'Rain forecast all weekend, so the hike is off. Movie marathon instead?',
  'Grandad says thanks for the photos. He printed one and put it on the mantel.',
  'The quote came in higher than expected. I think we should get a second opinion.',
  'New neighbours moved in next door. They have a dog that already likes me more than you do.',
  'Power was out for an hour tonight. Candles, cards, and terrible ghost stories.',
  'I fixed the leak under the sink. Only flooded the cupboard a little bit this time.',
  'Tickets go on sale Friday at nine sharp. Set an alarm, they sold out fast last year.',
];

// "<scenario> r<rep> m<n> T<total>" followed by natural-language text,
// cut to exactly BODY_SIZE bytes — same size/uniqueness contract as the
// other systems' drivers.
function msgBody(scenario, rep, n, total) {
  const tag = `${scenario} r${rep} m${n} T${total}`;
  if (tag.length > BODY_SIZE) throw new Error(`tag too long: ${tag}`);
  let body = tag;
  let i = (n - 1) % BODY_CORPUS.length;
  while (body.length < BODY_SIZE) {
    body += ' ' + BODY_CORPUS[i];
    i = (i + 1) % BODY_CORPUS.length;
  }
  return body.slice(0, BODY_SIZE);
}

// Parse a bench body back into its parts; null if not a bench message.
function parseTag(body) {
  const m = /^(m\d+p\d+(?:a\d+[km])?(?:-fwd|-br)?) r(\d+) m(\d+) T(\d+)/.exec(body || '');
  if (!m) return null;
  const scenario = m[1];
  const pMatch = /p(\d+)/.exec(scenario);
  return {
    scenario,
    rep: parseInt(m[2], 10),
    n: parseInt(m[3], 10),
    total: parseInt(m[4], 10),
    participants: pMatch ? parseInt(pMatch[1], 10) : 2,
    branch: scenario.endsWith('-br'),
  };
}

// Sender participant index for message n (1 = the bench/local side).
// Mirrors the fmsg/email drivers: alternation for 2 parties, round-robin
// otherwise; branch scenarios: every message after the first is remote.
function senderIndex(n, participants, branch) {
  if (n === 1) return 1;
  if (branch) return 2;
  return ((n - 1) % participants) + 1;
}

// A previous container run leaves Chromium Singleton{Lock,Cookie,Socket}
// symlinks in the persisted session volume; with a new container
// hostname Chromium refuses to start. They're only meaningful within a
// single boot — always safe to clear here, before launch.
function clearStaleLocks(sessionDir, clientId) {
  const profile = path.join(sessionDir, `session-${clientId}`);
  for (const name of ['SingletonLock', 'SingletonCookie', 'SingletonSocket']) {
    try { fs.rmSync(path.join(profile, name), { force: true }); } catch (_) { /* best effort */ }
  }
}

function makeClient(sessionDir, clientId) {
  clearStaleLocks(sessionDir, clientId);
  return new Client({
    authStrategy: new LocalAuth({ clientId, dataPath: sessionDir }),
    puppeteer: {
      executablePath: process.env.WA_CHROMIUM_PATH || undefined,
      args: ['--no-sandbox', '--disable-setuid-sandbox', '--disable-dev-shm-usage'],
    },
  });
}

// Chromium load can fail transiently in rootless containers (e.g.
// ERR_NETWORK_CHANGED while sibling containers plumb their veths) —
// retry instead of crash-looping, which would itself flap the netns.
async function initializeWithRetry(client, label, sessionDir, clientId, delayMs = 15000) {
  for (;;) {
    try {
      await client.initialize();
      return;
    } catch (err) {
      console.error(`${label}: initialize failed (${err.message}); retrying in ${delayMs / 1000}s`);
      try { await client.destroy(); } catch (_) { /* best effort */ }
      clearStaleLocks(sessionDir, clientId);
      await new Promise((r) => setTimeout(r, delayMs));
    }
  }
}

module.exports = { BODY_SIZE, msgBody, parseTag, senderIndex, makeClient, initializeWithRetry };
