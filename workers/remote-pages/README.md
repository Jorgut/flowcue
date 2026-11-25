# FlowCue Pages relay proxy

`_worker.js` proxies HTTP and WebSocket traffic from
`https://flowcue-relay.pages.dev` to the existing Worker at
`https://flowcue-remote.honaler.workers.dev`.

The two hostnames share the same Durable Objects, pair records and encrypted
relay state. The Pages hostname is used because some mobile networks block
`*.workers.dev` but allow `*.pages.dev`.

Deploy from `workers/remote`:

```bash
./node_modules/.bin/wrangler pages deploy ../remote-pages \
  --project-name flowcue-relay --branch main --no-bundle
```
