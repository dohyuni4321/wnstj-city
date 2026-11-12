# CRIME CITY 3D · 멀티플레이

친구가 만든 CRIME CITY 3D 원본에 Supabase Realtime 멀티플레이를 붙인 버전.

**플레이:** https://dohyuni4321.github.io/wnstj-city/

## 멀티 방법
1. 접속하면 바로 싱글플레이로 시작되고, 왼쪽 아래에 **내 방 코드**가 표시됨
2. 친구가 자기 화면의 "친구 방 코드"에 그 코드를 입력하고 **참가**
3. 같은 도시에서 서로의 캐릭터·차량·총알·폭발이 보이고 채팅 가능 (인원 제한 없음)
4. "내 방으로 돌아가기"로 언제든 다시 내 방(싱글)으로

## 조작 추가/변경
- Space: 점프 (차량에서는 기존대로 핸드브레이크/사격)
- 좌클릭 또는 X: 도보 사격
- Enter: 채팅
- 모바일: JUMP 버튼

## 협동 요소
- 은행/가게 강탈 성공 시 근처(600 이내) 팀원에게 30% 팀 보너스
- 돈은 브라우저에 자동 저장

## 구조
- `index.html` — 게임 (원본 + 멀티 레이어), GitHub Pages로 배포
- `original-crime-city-3d.html` — 수정 전 원본
- 실시간 통신: Supabase Realtime (Broadcast + Presence), 별도 서버 불필요
- `server/` — 이전에 만든 Render WebSocket 서버 (현재 게임에서는 사용하지 않음)
