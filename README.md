# Todo

군더더기 없는 할 일 앱. 맥 앱(SwiftUI)과 아이폰용 웹 앱이 같은 목록을 씁니다.

- 일간 · 주간 · 월간 보기, 라이트 · 다크 모드
- 끝내지 못한 할 일은 다음 날 자동으로 오늘로 넘어옴
- 로그인 없음: 맥이 가진 비밀 연결 코드로만 서버의 목록에 접근

## 구성

| 폴더 | 내용 |
|---|---|
| `mac/` | 맥 앱. `TodoCore`(날짜 · 순서 · 동기화 규칙, 테스트 있음) + `Todo`(화면) |
| `web/` | 아이폰 웹 앱. GitHub Pages로 배포 (`.github/workflows/pages.yml`) |
| `supabase/todo.sql` | 서버 쪽 테이블과 함수. 공용 Supabase 프로젝트의 `todo` 스키마 |
| `scripts/` | 맥 앱 빌드 · 아이콘 생성 |

## 맥 앱 빌드

```sh
./scripts/build-mac.sh        # build/Todo.app 생성
cd mac && swift test          # 규칙 테스트 (Xcode 툴체인 필요)
```

## 아이폰 연결

맥 앱 메뉴 **파일 → 아이폰 연결…** 의 QR 코드를 아이폰 카메라로 찍고,
Safari 공유 버튼 → **홈 화면에 추가**.

## 동기화 방식

- 할 일마다 `updated_at`(밀리초)을 찍고, 같은 할 일은 더 나중에 바뀐 쪽이 이깁니다.
- 바뀐 할 일은 서버가 받을 때까지 기기에 남아 있어서 인터넷이 끊겨도 잃지 않습니다.
- 앱은 `todo_pull` · `todo_push` 함수만 부르고, 두 함수는 연결 코드가 맞을 때만 동작합니다.
  서버에는 연결 코드의 SHA-256 해시만 저장됩니다.
- 연결 코드는 맥의 `~/Library/Application Support/Todo/sync.json`에만 있고 이 저장소에는 없습니다.
