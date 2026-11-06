// Instabox free-plan keepalive.
//
// Deployed as a Cloudflare Worker with a cron trigger every minute. The free
// plan starts each run with a 2-hour window; activity can extend it by 2 hours
// at a time up to 8 hours. Five minutes before the deadline Instabox decides
// whether to extend. A manual pause ends the run with no cooldown owed, and the
// next resume starts a fresh window. This Worker watches maxRunMinutes and,
// shortly before the deadline, does a quick suspend + resume.
//
// Bindings:
//   INSTABOX_API_KEY           secret, required (machines:read + machines:write)
//   INSTABOX_MACHINE_ID        plain text, production machine
//   PUBLIC_READY_URL           plain text, https://whatsapp.oppertunity.xyz/ready
//   RESET_AFTER_MINUTES        plain text, default 360
//   SAFETY_MARGIN_MINUTES      plain text, default 4
//   MIN_AGE_BEFORE_RESET       plain text, default 60
//   TEST_TOKEN                 secret, required only for GET /check
//   ALERT_WEBHOOK_URL          secret, optional Slack/Discord webhook
//
// Manual check: curl -H "x-test-token: $TEST_TOKEN" \
//   https://instabox-keepalive.<account>.workers.dev/check
// Manual reset: same URL with /reset (dry-run with /check).

const API = "https://api.instabox.sh";

export default {
  async scheduled(event, env, ctx) {
    ctx.waitUntil(
      run(env, false).catch((e) =>
        alert(env, "Instabox keepalive failed: " + (e && e.message ? e.message : String(e)))
      )
    );
  },

  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.pathname === "/check" || url.pathname === "/reset") {
      if (!env.TEST_TOKEN || request.headers.get("x-test-token") !== env.TEST_TOKEN) {
        return new Response("forbidden", { status: 403 });
      }
      const force = url.pathname === "/reset";
      try {
        return Response.json(await run(env, !force, force));
      } catch (e) {
        return Response.json({ ok: false, error: String(e) }, { status: 500 });
      }
    }
    return new Response("instabox keepalive", { status: 200 });
  },
};

async function run(env, dryRun, force) {
  const machineId = env.INSTABOX_MACHINE_ID || "m_agqwaleqeg6hzdoppoerxokgwa";
  const headers = { "X-API-Key": env.INSTABOX_API_KEY, Accept: "application/json" };

  const mres = await fetch(API + "/v1/machines/" + machineId, { headers });
  if (!mres.ok) {
    const body = (await mres.text()).slice(0, 300);
    throw new Error("GET machine HTTP " + mres.status + ": " + body);
  }
  const m = await mres.json();
  const now = Date.now();

  if (m.cooldownUntil) {
    const until = Date.parse(m.cooldownUntil);
    if (until > now) {
      const minutes = Math.ceil((until - now) / 60000);
      const msg = "Instabox machine is in cooldown until " + m.cooldownUntil + " (~" + minutes + " min). Service is down.";
      console.log(msg);
      if (new Date().getUTCMinutes() % 15 === 0) await alert(env, msg);
      return { ok: false, cooldown: true, cooldownUntil: m.cooldownUntil, minutes, state: m.state };
    }
  }

  if (m.state === "suspended") {
    const action = m.autoSuspendedAt ? "wake" : "resume";
    if (dryRun) return { ok: true, dryRun: true, action, state: m.state };
    await lifecycle(env, machineId, action);
    await waitReady(env, 90000);
    return { ok: true, action, state: m.state };
  }

  if (m.state !== "running") {
    return { ok: true, action: "none", state: m.state };
  }

  const age = (now - Date.parse(m.runStartedAt)) / 60000;
  const maxRun = Number(m.maxRunMinutes || 480);
  const remaining = maxRun - age;
  const resetAfter = Number(env.RESET_AFTER_MINUTES || 360);
  const margin = Number(env.SAFETY_MARGIN_MINUTES || 4);
  const minAge = Number(env.MIN_AGE_BEFORE_RESET || 60);
  const shouldReset = force || (age >= minAge && (age >= resetAfter || remaining <= margin));
  const info = {
    ok: true,
    dryRun,
    state: m.state,
    age: Math.round(age * 10) / 10,
    maxRun,
    remaining: Math.round(remaining * 10) / 10,
    resetAfter,
    margin,
    minAge,
    shouldReset,
  };

  if (!shouldReset) return info;
  if (dryRun) return Object.assign(info, { action: "suspend+resume" });

  let suspended = false;
  try {
    await lifecycle(env, machineId, "suspend");
    suspended = true;
    await lifecycle(env, machineId, "resume");
    await waitReady(env, 90000);
  } catch (e) {
    if (suspended) {
      try {
        await lifecycle(env, machineId, "resume");
      } catch (e2) {
        console.error("cleanup resume failed: " + String(e2));
      }
    }
    throw e;
  }
  return Object.assign(info, { action: "suspend+resume", reset: true });
}

async function lifecycle(env, machineId, action) {
  const res = await fetch(API + "/v1/machines/" + machineId + "/" + action, {
    method: "POST",
    headers: {
      "X-API-Key": env.INSTABOX_API_KEY,
      "Content-Type": "application/json",
      "Idempotency-Key": crypto.randomUUID(),
    },
    body: "{}",
  });
  const text = await res.text();
  if (!res.ok) throw new Error(action + " HTTP " + res.status + ": " + text.slice(0, 300));

  const op = JSON.parse(text);
  const opId = op.id || (op.operation && op.operation.id);
  if (!opId) return;

  for (let i = 0; i < 12; i++) {
    await sleep(5000);
    const r = await fetch(API + "/v1/operations/" + opId, {
      headers: { "X-API-Key": env.INSTABOX_API_KEY },
    });
    if (!r.ok) continue;
    const o = await r.json();
    if (o.state === "succeeded") return;
    if (o.state === "failed") {
      throw new Error(action + " failed: " + JSON.stringify(o.error).slice(0, 300));
    }
  }
  throw new Error(action + " operation " + opId + " timed out");
}

async function waitReady(env, timeoutMs) {
  const url = env.PUBLIC_READY_URL || "https://whatsapp.oppertunity.xyz/ready";
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    try {
      const r = await fetch(url, { cf: { cacheTtl: 0 } });
      if (r.ok) return true;
    } catch (e) {
      // keep polling
    }
    await sleep(5000);
  }
  throw new Error("ready timeout: " + url);
}

async function alert(env, text) {
  console.log(text);
  if (!env.ALERT_WEBHOOK_URL) return;
  try {
    await fetch(env.ALERT_WEBHOOK_URL, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ text: text, content: text }),
    });
  } catch (e) {
    console.error("alert failed: " + String(e));
  }
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}
