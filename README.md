# TH3V151T0R5_F - 조사봇

마스토돈 기반 RPG 커뮤니티 THE VISITORS의 조사/탐색 자동봇입니다.
Google Sheets와 연동하여 장소 이동, 오브젝트 조사, 아이템 획득을 처리합니다.
모든 응답은 DM(다이렉트 메시지)으로 발송됩니다.

## 명령어

| 명령어 | 설명 |
|--------|------|
| `[위치/장소명]` | 해당 장소로 이동. 지문과 이동 가능한 장소 목록을 DM으로 수신 |
| `[둘러보기]` | 현재 위치의 오브젝트 목록을 DM으로 수신 |
| `[조사/오브젝트명]` | 오브젝트 상호작용. 결과 및 아이템 획득을 DM으로 수신 |

## 스프레드시트 구조

### 장소 시트
| 열 | 항목 | 설명 |
|----|------|------|
| A | 장소명 | 고유 이름 |
| B | 지문 | 장소 설명 텍스트 |
| C~F | 선택지1~4 | 이동 가능한 장소명 |
| G | 공개여부 | FALSE = 접근 불가 |
| H | 오브젝트명 | 상호작용 대상 이름 |
| I | 조사결과 | 조사 시 출력 텍스트 |
| J | 획득아이템 | 아이템명 (없으면 빈칸) |
| K | 1회한정 | TRUE = 1회만 획득 가능 |
| L | 획득자ID | 이미 가져간 유저 ID (콤마 구분) |

장소 1개에 오브젝트가 여러 개일 경우, 장소명/지문/선택지는 첫 행에만 입력하고 이후 행은 H~L만 채웁니다.

### 조사상태 시트
| 열 | 항목 |
|----|------|
| A | 유저 ID |
| B | 현재위치 |
| C | 이전행동 |

### 사용자 시트
기존 자동봇 시트의 사용자 시트를 공유합니다.

## 환경변수 (.env)

```env
MASTODON_BASE_URL=https://th3v151t0r5.bond
MASTODON_TOKEN=your_token
GOOGLE_SHEET_ID=your_sheet_id
GOOGLE_APPLICATION_CREDENTIALS=/root/TH3V151T0R5_F/credentials.json
TZ=Asia/Seoul
```

## 설치 및 실행

```bash
git clone https://github.com/CriminalTalent/TH3V151T0R5_F.git
cd TH3V151T0R5_F
bundle install
cp /path/to/.env .env
cp /path/to/credentials.json credentials.json
pm2 start main.rb --name scout_bot --interpreter ruby
pm2 save
```
