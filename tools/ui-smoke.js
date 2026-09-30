// Minimal DOM shim so index.html's inline script can be executed in Node and the
// new Cloudflare connect panel can be smoke-tested end to end (render + fetches).
const fs = require('fs');
const path = require('path');

const BASE = process.env.CLOAK_BASE || 'http://127.0.0.1:3000';

function esc(s) {
  return String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;')
    .replace(/>/g, '&gt;').replace(/"/g, '&quot;');
}

class El {
  constructor(id) {
    this.id = id;
    this._text = '';
    this._html = '';
    this.value = '';
    this.disabled = false;
    this.textContent = '';
    this.style = {};
    this.dataset = {};
    this.children = [];
    const cls = new Set();
    this.classList = {
      add: (c) => cls.add(c),
      remove: (c) => cls.delete(c),
      toggle: (c) => (cls.has(c) ? cls.delete(c) : cls.add(c)),
      contains: (c) => cls.has(c),
    };
    Object.defineProperty(this, 'textContent', {
      get: () => this._text,
      set: (v) => { this._text = String(v); this._html = esc(v); },
    });
    Object.defineProperty(this, 'innerHTML', {
      get: () => this._html,
      set: (v) => { this._html = String(v); },
    });
  }
  addEventListener() {}
  scrollIntoView() {}
  focus() {}
  select() {}
  appendChild(c) { this.children.push(c); }
  removeChild(c) { this.children = this.children.filter((x) => x !== c); }
}

const nodes = new Map();
global.document = {
  getElementById: (id) => {
    if (!nodes.has(id)) nodes.set(id, new El(id));
    return nodes.get(id);
  },
  createElement: (tag) => new El('<' + tag + '>'),
  body: new El('body'),
};
global.window = { location: { host: 'localhost:3000', href: '' } };
global.navigator = { clipboard: { writeText: async () => {} } };

// relative fetch → absolute
const realFetch = global.fetch;
global.fetch = (url, opts) => realFetch(url.startsWith('/') ? BASE + url : url, opts);

const html = fs.readFileSync(path.join(__dirname, '..', 'index.html'), 'utf8');
const code = [...html.matchAll(/<script>([\s\S]*?)<\/script>/g)].map((m) => m[1]).join('\n');
// strip the trailing auto-run so we control the calls
const body = code.replace(/\nloadStats\(\);\nloadRecent\(\);\nloadDomains\(\);[\s\S]*$/, '\n');
// eslint-disable-next-line no-new-func
const run = new Function('return (async () => {' + body + `
  await loadDomains();
  await openConnect('links.example.com', false);
  const panel = document.getElementById('cfPanel').innerHTML;
  await verifyDomain(cf.domain);
  const afterVerify = document.getElementById('cfPanel').innerHTML;
  renderAdvice({domain: 'brand-new.example.com', verified: false, reason: 'not checked',
                service: 'http://cloak:3000', links: {tunnel_create: 'https://one.dash.cloudflare.com/x'}});
  return {
    panel, afterVerify,
    advice: document.getElementById('adviceText').innerHTML + document.getElementById('adviceActions').innerHTML,
    adviceShown: document.getElementById('domainAdvice').classList.contains('show'),
    list: document.getElementById('domainList').innerHTML,
    datalist: document.getElementById('savedDomains').innerHTML,
    datalistAfterVerify: (await loadDomains(), document.getElementById('savedDomains').innerHTML),
    cfError: document.getElementById('cfError').innerHTML,
    hasXss: /<script>alert/.test(panel + afterVerify),
  };
})()`);

fetch(BASE + '/api/health').then((r) => r.json()).then((h) => {
  if (h.app !== 'cloak-url') throw new Error('CLOAK_BASE is not a Cloak.URL instance: ' + BASE);
  console.log('target:', BASE, '| base_domain:', h.base_domain);
  return run();
}).then((out) => {
  const flag = (name, ok) => console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}`);
  flag('setup panel rendered', out.panel.includes('Create a tunnel') || out.panel.includes('Open Cloudflare'));
  flag('panel shows hostname + service', out.panel.includes('links.example.com') && out.panel.includes('http://cloak:3000'));
  flag('panel shows 4 numbered steps', (out.panel.match(/class="step-num"/g) || []).length === 4);
  flag('verify rendered a status box', out.afterVerify.includes('cf-status show'));
  flag('verify reported a state pill', /pill (ok|warn|bad|mute)/.test(out.afterVerify));
  flag('advice banner shown', out.adviceShown && out.advice.includes('brand-new.example.com'));
  flag('advice links to Cloudflare', out.advice.includes('one.dash.cloudflare.com'));
  flag('domain list rendered', out.list.includes('links.example.com'));
  flag('datalist filled after verify', out.datalistAfterVerify.includes('links.example.com'));
  flag('no inline error', out.cfError === '');
  flag('no raw script injection', !out.hasXss);
  process.exit(0);
}).catch((e) => {
  console.error('\nCannot run the UI smoke test (' + e.message + ').');
  console.error('Start the app first:  DB_PATH=/tmp/c.db python3 app.py   (or set CLOAK_BASE)');
  process.exit(2);
});
