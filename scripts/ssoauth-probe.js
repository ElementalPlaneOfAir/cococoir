#!/usr/bin/env node
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// ssoauth-probe.js — prove CryptPad's SSO callback works against the
// live vmtest. It walks the full challenge protocol (SSO_AUTH -> Dex
// local login + approval -> SSO_AUTH_CB) and expects a signed JWT back.
//
// This is the tripwire for the cryptpad first-boot bearer-secret bug:
// on a broken first boot, api.js writes SET_BEARER_SECRET but never
// applies it to the running process, so SSO_AUTH_CB dies with
// "secretOrPrivateKey must have a value" and the /ssoauth page hangs.
//
// Runs on the VM. The node binary and tweetnacl come from the running
// cryptpad unit (no host deps). Usage:
//   node scripts/ssoauth-probe.js [cryptpadBase] [dexBase]
// Defaults: https://cryptpad.vmtest.local https://auth.vmtest.local

const CP = process.argv[2] || 'https://cryptpad.vmtest.local';
const DEX = process.argv[3] || 'https://auth.vmtest.local';
const DEX_USER = 'admin@example.com';
const DEX_PASS = 'password';

const { execSync } = require('node:child_process');
const mainPid = execSync('systemctl show cryptpad -p MainPID --value').toString().trim();
const nodePath = execSync(`readlink -f /proc/${mainPid}/exe`).toString().trim();
const execStart = execSync('systemctl show cryptpad -p ExecStart --value').toString().trim();
const pkgMatch = execStart.match(/(\/nix\/store\/[a-z0-9]+-cryptpad-with-sso[^/]*)/);
if (!pkgMatch) {
  console.error('ssoauth-probe: cannot locate cryptpad package in ExecStart', execStart);
  process.exit(2);
}
const Nacl = require(`${pkgMatch[1]}/lib/node_modules/cryptpad/node_modules/tweetnacl/nacl-fast.js`);

const b64 = (u8) => Buffer.from(u8).toString('base64');
const utf8 = (s) => new Uint8Array(Buffer.from(s, 'utf8'));

let cookies = {};
const jar = (url) => {
  const host = new URL(url).host;
  return Object.entries(cookies[host] || {}).map(([k, v]) => `${k}=${v}`).join('; ');
};
const saveCookies = (url, setCookie) => {
  if (!setCookie) return;
  const host = new URL(url).host;
  cookies[host] = cookies[host] || {};
  for (const line of setCookie) {
    const [pair] = line.split(';');
    const [k, v] = pair.split('=');
    cookies[host][k] = v;
  }
};

async function post(url, body) {
  const res = await fetch(url, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'Cookie': jar(url) },
    body: JSON.stringify(body),
    redirect: 'manual',
  });
  saveCookies(url, res.headers.getSetCookie ? res.headers.getSetCookie() : res.headers.get('set-cookie') && [res.headers.get('set-cookie')]);
  const text = await res.text();
  let json = null;
  try { json = JSON.parse(text); } catch (e) {}
  return { status: res.status, json, headers: res.headers };
}

async function serverCommand(keypair, data) {
  const obj = { ...data, publicKey: b64(keypair.publicKey), nonce: b64(Nacl.randomBytes(24)) };
  const res = await post(`${CP}/api/auth/`, obj);
  if (!res.json || !res.json.txid || !res.json.date) {
    throw new Error(`stage1 failed: ${res.status} ${JSON.stringify(res.json)}`);
  }
  const { txid, date } = res.json;
  const copy = { ...obj, txid, date };
  const toSign = utf8(JSON.stringify(copy));
  const sig = b64(Nacl.sign.detached(toSign, keypair.secretKey));
  const res2 = await post(`${CP}/api/auth/`, { sig, txid });
  if (res2.status !== 200) {
    throw new Error(`stage2 failed: ${res2.status} ${JSON.stringify(res2.json)}`);
  }
  return res2.json;
}

async function followToFinal(url, maxHops = 20) {
  let cur = url;
  for (let i = 0; i < maxHops; i++) {
    const res = await fetch(cur, { method: 'GET', redirect: 'manual', headers: { 'Cookie': jar(cur) } });
    saveCookies(cur, res.headers.getSetCookie ? res.headers.getSetCookie() : res.headers.get('set-cookie') && [res.headers.get('set-cookie')]);
    const loc = res.headers.get('location');
    if (!loc || (res.status < 300 || res.status >= 400)) {
      return { status: res.status, url: cur, headers: res.headers };
    }
    cur = new URL(loc, cur).href;
  }
  throw new Error('too many redirects');
}

async function dexLogin(authUrl) {
  const s1 = await followToFinal(authUrl);
  const formUrl = s1.url;
  const res = await fetch(formUrl, {
    method: 'POST',
    redirect: 'manual',
    headers: {
      'Content-Type': 'application/x-www-form-urlencoded',
      'Cookie': jar(formUrl),
    },
    body: new URLSearchParams({ login: DEX_USER, password: DEX_PASS }).toString(),
  });
  saveCookies(formUrl, res.headers.getSetCookie ? res.headers.getSetCookie() : res.headers.get('set-cookie') && [res.headers.get('set-cookie')]);
  let loc = res.headers.get('location');
  if (!loc) {
    const body = await res.text();
    throw new Error(`dex login no redirect: ${res.status} ${body.slice(0, 300)}`);
  }
  let cur = new URL(loc, formUrl).href;
  if (cur.includes('/dex/approval')) {
    const req = new URL(cur).searchParams.get('req');
    const ares = await fetch(cur, {
      method: 'POST',
      redirect: 'manual',
      headers: {
        'Content-Type': 'application/x-www-form-urlencoded',
        'Cookie': jar(cur),
      },
      body: new URLSearchParams({ req, approval: 'approve' }).toString(),
    });
    saveCookies(cur, ares.headers.getSetCookie ? ares.headers.getSetCookie() : ares.headers.get('set-cookie') && [ares.headers.get('set-cookie')]);
    const aloc = ares.headers.get('location');
    if (!aloc) throw new Error(`dex approval no redirect: ${ares.status}`);
    cur = new URL(aloc, cur).href;
  }
  return cur;
}

(async () => {
  const keypair = Nacl.sign.keyPair();
  const authRes = await serverCommand(keypair, { command: 'SSO_AUTH', provider: 'dex', register: true });
  const callbackUrl = await dexLogin(authRes.url);
  const cbRes = await serverCommand(keypair, { command: 'SSO_AUTH_CB', url: callbackUrl });
  if (cbRes.jwt) {
    console.log(`ssoauth-probe: PASS — SSO_AUTH_CB returned a JWT for "${cbRes.name}"`);
    process.exit(0);
  }
  console.error(`ssoauth-probe: FAIL — no JWT: ${JSON.stringify(cbRes)}`);
  process.exit(1);
})().catch((e) => {
  console.error('ssoauth-probe: FAIL —', e.message);
  process.exit(1);
});
