const http = require('http');
const { WebSocketServer } = require('ws');

const PORT = process.env.PORT || 3000;

const server = http.createServer((req, res) => {
  res.writeHead(200, { 'Content-Type': 'text/plain' });
  res.end('wnstj CITY server');
});

const wss = new WebSocketServer({ server });
const rooms = new Map();

function getRoom(code) {
  if (!rooms.has(code)) rooms.set(code, { players: new Map(), lastSend: 0 });
  return rooms.get(code);
}

function broadcast(room, message) {
  const data = JSON.stringify(message);
  for (const p of room.players.values()) {
    if (p.ws.readyState === 1) p.ws.send(data);
  }
}

wss.on('connection', ws => {
  let playerId = null;
  let room = null;

  ws.on('message', raw => {
    let msg;
    try { msg = JSON.parse(raw); } catch { return; }

    if (msg.t === 'join') {
      const code = String(msg.room || '').toUpperCase().slice(0, 6);
      if (!code) return;

      room = getRoom(code);
      playerId = 'p' + Math.random().toString(36).slice(2, 10);

      const colors = ['#ff4d6d', '#4da6ff', '#7bd44a', '#ffc400'];

      room.players.set(playerId, {
        ws,
        id: playerId,
        name: String(msg.name || '플레이어').slice(0, 12),
        color: colors[room.players.size % colors.length],
        x: 450,
        y: 280,
        a: 0,
        onFoot: true,
        lastMove: Date.now()
      });

      ws.send(JSON.stringify({
        t: 'welcome',
        id: playerId,
        room: code,
        color: room.players.get(playerId).color
      }));

      broadcast(room, { t: 'system', text: msg.name + '님이 입장했습니다.' });
      return;
    }

    if (!room || !playerId) return;
    const me = room.players.get(playerId);
    if (!me) return;

    if (msg.t === 'move') {
      const now = Date.now();
      if (now - me.lastMove < 50) return;
      me.lastMove = now;

      const nx = Number(msg.x) || 0;
      const ny = Number(msg.y) || 0;
      const dist = Math.hypot(nx - me.x, ny - me.y);

      if (dist < 80) {
        me.x = nx;
        me.y = ny;
        me.a = Number(msg.a) || 0;
        me.onFoot = !!msg.onFoot;
      }
      return;
    }

    if (msg.t === 'chat') {
      const text = String(msg.text || '').slice(0, 120);
      if (!text) return;
      broadcast(room, { t: 'chat', id: playerId, name: me.name, text });
      return;
    }
  });

  ws.on('close', () => {
    if (!room || !playerId) return;
    const me = room.players.get(playerId);
    room.players.delete(playerId);
    if (me) broadcast(room, { t: 'system', text: me.name + '님이 퇴장했습니다.' });
    if (room.players.size === 0) rooms.delete(room);
  });
});

setInterval(() => {
  const now = Date.now();
  for (const room of rooms.values()) {
    if (now - room.lastSend < 100) continue;
    room.lastSend = now;

    const players = [];
    for (const p of room.players.values()) {
      players.push({
        id: p.id,
        name: p.name,
        color: p.color,
        x: p.x,
        y: p.y,
        a: p.a,
        onFoot: p.onFoot
      });
    }

    for (const p of room.players.values()) {
      if (p.ws.readyState === 1) {
        p.ws.send(JSON.stringify({ t: 'state', players }));
      }
    }
  }
}, 100);

server.listen(PORT, () => {
  console.log('wnstj CITY server running on port ' + PORT);
});
