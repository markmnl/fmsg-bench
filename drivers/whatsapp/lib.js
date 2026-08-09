// Shared helpers for the whatsapp bot/responder.
'use strict';

const fs = require('fs');
const path = require('path');
const { Client, LocalAuth } = require('whatsapp-web.js');

const BODY_SIZE = 120;

// "<scenario> r<rep> m<n> T<total>" padded with '.' to exactly BODY_SIZE
// bytes — same size/uniqueness contract as the other systems' drivers.
function msgBody(scenario, rep, n, total) {
  const tag = `${scenario} r${rep} m${n} T${total}`;
  if (tag.length > BODY_SIZE) throw new Error(`tag too long: ${tag}`);
  return tag + '.'.repeat(BODY_SIZE - tag.length);
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
