import { Client } from 'ssh2';

const [cmd, ...hosts] = process.argv.slice(2);
const USER = 'root', PASS = 'root';

function run(host, command) {
  return new Promise((resolve) => {
    const conn = new Client();
    let buf = '';
    conn.on('ready', () => {
      conn.exec(command, (err, stream) => {
        if (err) { conn.end(); return resolve({ host, error: err.message }); }
        stream.on('data', (d) => (buf += d.toString()));
        stream.stderr.on('data', (d) => (buf += d.toString()));
        stream.on('close', () => { conn.end(); resolve({ host, out: buf.trim() }); });
      });
    });
    conn.on('error', (e) => resolve({ host, error: e.message }));
    conn.connect({ host, port: 22, username: USER, password: PASS, readyTimeout: 15000 });
  });
}

for (const h of hosts) {
  const r = await run(h, cmd);
  console.log(`===== ${h} =====`);
  console.log(r.error ? `ERROR: ${r.error}` : r.out);
  console.log('');
}
