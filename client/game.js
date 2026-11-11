const SUPABASE_URL = "https://eyiweluikqptpltdbind.supabase.co";
const SUPABASE_ANON_KEY = "sb_publishable_2HSCefmudZ2dM39UsDhbjQ_xUdBlTHy";

const supabase = window.supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY);

let channel = null;
let me = { id: null, name: "", x: 450, y: 280, a: 0, color: "#4da6ff", ready: false };
const others = new Map();
const keys = {};
let lastSend = 0;

const canvas = document.getElementById("c");
const ctx = canvas.getContext("2d");

addEventListener("keydown", e => keys[e.key.toLowerCase()] = 1);
addEventListener("keyup", e => keys[e.key.toLowerCase()] = 0);

document.getElementById("chatInput").addEventListener("keydown", e => {
  if (e.key === "Enter") sendChat();
});

function joinGame() {
  const name = document.getElementById("nickname").value.trim();
  const room = document.getElementById("roomCode").value.trim().toUpperCase();

  if (!name || !room) {
    document.getElementById("status").innerText = "닉네임과 방 코드를 입력하세요.";
    return;
  }

  me.name = name;
  me.color = "#" + Math.floor(Math.random() * 0xffffff).toString(16).padStart(6, "0");

  channel = supabase.channel("room:" + room, {
    config: { presence: { key: crypto.randomUUID() } }
  });

  channel
    .on("presence", { event: "sync" }, () => {
      const state = channel.presenceState();
      others.clear();

      for (const id in state) {
        const p = state[id][0];
        if (!p || p.clientId === me.id) continue;
        others.set(id, p);
      }

      updatePlayerList();
    })
    .on("broadcast", { event: "move" }, ({ payload }) => {
      if (payload.id === me.id) return;
      others.set(payload.id, { ...(others.get(payload.id) || {}), ...payload });
    })
    .on("broadcast", { event: "chat" }, ({ payload }) => {
      console.log(`${payload.name}: ${payload.text}`);
    })
    .on("broadcast", { event: "ready" }, ({ payload }) => {
      const p = others.get(payload.id);
      if (p) p.ready = payload.ready;
      updatePlayerList();
    })
    .subscribe(status => {
      if (status === "SUBSCRIBED") {
        me.id = crypto.randomUUID();

        channel.track({
          clientId: me.id,
          name: me.name,
          color: me.color,
          x: me.x,
          y: me.y,
          ready: false
        });

        document.getElementById("login").style.display = "none";
        document.getElementById("game").style.display = "block";
        document.getElementById("chat").style.display = "flex";
        document.getElementById("roomLabel").innerText = room;
        document.getElementById("status").innerText = "연결됨";
      }
    });

  requestAnimationFrame(loop);
}

function updatePlayerList() {
  const box = document.getElementById("players");
  box.innerHTML = "";

  const all = [{ ...me, clientId: me.id }, ...others.values()];

  for (const p of all) {
    const span = document.createElement("span");
    span.style.color = p.color;
    span.innerText = p.name + (p.ready ? " ✔" : "");
    box.appendChild(span);
  }
}

function toggleReady() {
  me.ready = !me.ready;

  channel.send({
    type: "broadcast",
    event: "ready",
    payload: { id: me.id, ready: me.ready }
  });

  channel.track({
    clientId: me.id,
    name: me.name,
    color: me.color,
    x: me.x,
    y: me.y,
    ready: me.ready
  });

  updatePlayerList();
}

function sendChat() {
  const input = document.getElementById("chatInput");
  const text = input.value.trim();

  if (!text || !channel) return;

  channel.send({
    type: "broadcast",
    event: "chat",
    payload: { id: me.id, name: me.name, text }
  });

  input.value = "";
}

function update(dt) {
  let dx = 0, dy = 0;

  if (keys.a || keys.arrowleft) dx--;
  if (keys.d || keys.arrowright) dx++;
  if (keys.w || keys.arrowup) dy--;
  if (keys.s || keys.arrowdown) dy++;

  if (dx || dy) {
    const len = Math.hypot(dx, dy);
    me.x += dx / len * 220 * dt;
    me.y += dy / len * 220 * dt;
    me.a = Math.atan2(dy, dx);
  }

  me.x = Math.max(20, Math.min(canvas.width - 20, me.x));
  me.y = Math.max(20, Math.min(canvas.height - 20, me.y));

  if (channel && Date.now() - lastSend > 200) {
    lastSend = Date.now();

    channel.send({
      type: "broadcast",
      event: "move",
      payload: {
        id: me.id,
        name: me.name,
        color: me.color,
        x: me.x,
        y: me.y,
        a: me.a,
        ready: me.ready
      }
    });
  }
}

function draw() {
  ctx.fillStyle = "#20242f";
  ctx.fillRect(0, 0, canvas.width, canvas.height);

  ctx.strokeStyle = "#ffffff12";

  for (let x = 0; x < canvas.width; x += 60) {
    ctx.beginPath(); ctx.moveTo(x, 0); ctx.lineTo(x, canvas.height); ctx.stroke();
  }

  for (let y = 0; y < canvas.height; y += 60) {
    ctx.beginPath(); ctx.moveTo(0, y); ctx.lineTo(canvas.width, y); ctx.stroke();
  }

  for (const p of others.values()) drawPlayer(p.x, p.y, p.color, p.name);
  drawPlayer(me.x, me.y, me.color, me.name + " (나)");
}

function drawPlayer(x, y, color, name) {
  ctx.fillStyle = color;
  ctx.beginPath();
  ctx.arc(x, y, 16, 0, Math.PI * 2);
  ctx.fill();

  ctx.fillStyle = "#fff";
  ctx.font = "bold 13px system-ui";
  ctx.textAlign = "center";
  ctx.fillText(name, x, y - 24);
}

let last = performance.now();

function loop(now) {
  const dt = Math.min(0.05, (now - last) / 1000);
  last = now;

  update(dt);
  draw();
  requestAnimationFrame(loop);
}
