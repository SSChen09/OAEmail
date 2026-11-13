import { Client } from 'ssh2';

const HOSTS = process.argv.slice(2);
const USER = 'root';
const PASS = 'root';
const CMD = 'id; hostname; uname -sr; (cat /etc/os-release 2>/dev/null | grep -E "^(PRETTY_NAME|ID)=" ); ip -4 -o addr show 2>/dev/null | awk "{print \\$2, \\$4}"';

function run(host) {
  return new Promise((resolve) => {
    const conn = new Client();
    const out = { host, ok: false, banner: null, data: '', error: null, latencyMs: null };
    const t0 = Date.now();

    conn.on('banner', (b) => { out.banner = String(b).trim(); });
    conn.on('ready', () => {
      out.latencyMs = Date.now() - t0;
      conn.exec(CMD, (err, stream) => {
        if (err) { out.error = err.message; conn.end(); return resolve(out); }
        let buf = '';
        stream.on('data', (d) => { buf += d.toString(); });
        stream.stderr.on('data', (d) => { buf += d.toString(); });
        stream.on('close', () => {
          out.ok = true;
          out.data = buf.trim();
          conn.end();
          resolve(out);
        });
      });
    });
    conn.on('error', (e) => { out.error = `${e.level || ''}${e.message}`; resolve(out); });
    conn.connect({
      host, port: 22, username: USER, password: PASS,
      tryKeyboard: true,
      readyTimeout: 15000,
      algorithms: undefined,
    });
    conn.on('keyboard-interactive', (n, i, l, prompts, finish) => finish([PASS]));
  });
}

const results = [];
for (const h of HOSTS) results.push(await run(h));
console.log(JSON.stringify(results, null, 2));
