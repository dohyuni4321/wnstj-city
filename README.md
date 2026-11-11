# wnstj CITY

Supabase Realtime 기반 2~4인 멀티플레이 범죄 도시 게임 프로젝트입니다.

## 구성

- `client/`: GitHub Pages에 배포할 게임 클라이언트
- `server/`: Render에 배포할 Node.js WebSocket 서버
- `supabase/`: Supabase 테이블 및 RLS 마이그레이션

## Supabase 설정

1. Supabase Dashboard에서 `Capper` 프로젝트를 엽니다.
2. SQL Editor에서 `supabase/migration.sql`을 실행합니다.
3. Authentication > Providers에서 Anonymous sign-ins를 활성화합니다.
4. Project Settings > API에서 publishable key를 확인합니다.
5. `client/game.js`의 `SUPABASE_ANON_KEY`를 실제 publishable key로 교체합니다.

service_role key는 절대 GitHub에 올리지 마세요.

## 로컬 서버 실행

```bash
cd server
npm install
npm start
```

## GitHub Pages

Settings > Pages > Branch: `main`, Folder: `/ (root)`로 설정합니다.

## Render 배포

- Root Directory: `server`
- Build Command: `npm install`
- Start Command: `npm start`
