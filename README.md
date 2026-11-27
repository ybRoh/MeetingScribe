# 회의록 서기

회의록 서기는 Mac과 Windows용 한국어 회의 기록 앱입니다. 대면 회의는 컴퓨터 마이크로 기록합니다. Mac의 하이브리드 모드는 마이크와 선택한 Zoom·Teams 데스크톱 앱의 재생음을 분리해 받아씁니다. 한국어 받아쓰기는 Whisper, 회의록은 Qwen3와 llama.cpp로 기기에서 처리합니다. GitHub 배포 ZIP에는 실행 엔진이 들어 있으며, 처음 한 번 공개 모델을 다운로드합니다.

## 다운로드

- **[Mac 배포 ZIP · Apple Silicon](https://github.com/ybRoh/MeetingScribe/releases/download/v1.1.0/MeetingScribe-1.1.0-macOS-arm64.zip)**
  압축을 풀고 `Setup-Mac.command`를 처음 한 번 실행하세요. 이후에는 같은 폴더의 `회의록 서기.app`을 엽니다. 검증 환경은 macOS 27.0.1이며 Apple Developer ID 서명과 공증은 적용되지 않았습니다.
- **[Windows 배포 ZIP · Windows 11 x64](https://github.com/ybRoh/MeetingScribe/releases/download/v1.1.0/MeetingScribe-1.1.0-Windows-x64.zip)**
  전체 압축을 풀고 `Setup-Windows.cmd`를 처음 한 번 실행하세요. 이후에는 같은 폴더의 `MeetingScribe.exe`를 엽니다. [Microsoft Visual C++ Redistributable x64](https://learn.microsoft.com/en-us/cpp/windows/latest-supported-vc-redist)가 필요합니다. Windows판은 대면 회의 마이크 녹음을 지원하며, 기록 종료 후 받아쓰기를 시작합니다. 처리용 임시 녹음 파일은 처리 종료 시 삭제합니다.

최초 설정에서 모델 약 3 GB를 다운로드합니다. 이후 회의 내용은 기기에서 처리합니다. 회의록 하단 **To-Do List**의 각 항목은 업무, 담당자, 기한 순서입니다.

## Mac 개발 빌드 실행

- `dist/회의록 서기.app`을 Finder에서 엽니다.
- 이 Mac에는 두 모델을 배치해 두었습니다. 앱을 옮길 때 옆의 `models` 폴더도 같이 옮기세요.
- 다른 Mac에서 준비하려면 Xcode Command Line Tools와 Homebrew를 설치한 뒤 `brew install whisper.cpp llama.cpp`, `./setup-models.sh`, `./build.sh`를 실행하세요.
- 회의록 모델이 준비되지 않아도 받아쓰기를 진행할 수 있습니다. 모델을 준비한 뒤 **다시 생성**을 누르세요.

## 대면 회의

1. **기록 방식 → 대면 회의 · 마이크만**을 선택합니다. 앱을 처음 열면 이 방식이 기본입니다.
2. 참석자에게 알리고 동의를 받은 뒤 **기록 시작**을 누릅니다. 이 방식은 마이크 권한만 사용합니다.
3. **기록 종료** 후 회의록을 편집하고 복사하거나 Markdown으로 저장합니다.

## Zoom·Teams 회의

1. 회의실 장비와 Mac을 같은 Zoom 또는 Teams 회의에 연결합니다. Mac은 회의 앱 내에서 마이크를 음소거하고 컴퓨터 오디오는 연결해 둡니다. 이어폰이 있으면 Mac의 회의 오디오 출력을 이어폰으로 보내고, 회의실에서는 기존 TV나 스피커를 씁니다.
2. 회의 참가자의 동의를 받은 후 앱의 **기록 방식**에서 Zoom 또는 Teams를 선택하고 **기록 시작**을 누릅니다. 처음에는 마이크와 화면 및 시스템 오디오 녹음 권한을 허용하세요. 권한을 변경한 뒤 앱을 다시 열어야 할 수 있습니다.
3. 원격 참석자와 회의실 참석자가 각각 말할 때 **온라인**, **회의실** 음량과 자막이 들어오는지 확인합니다. 자막은 짧은 발언 구간마다 나타나며, 확정 자막을 바탕으로 회의록 초안을 약 1분마다 갱신합니다.
4. **기록 종료**를 누르면 받아쓰기를 마무리하고 회의록 초안을 다시 생성합니다. 필요하면 초안을 편집한 후 복사하거나 Markdown으로 저장합니다.

Mac 앱은 화면 영상을 저장하지 않습니다. 원본 음성은 파일로 저장하지 않으며, 받아쓰기와 회의록은 사용자가 파일로 저장하기 전까지 현재 앱 창에 유지됩니다. 새 회의 또는 앱 종료 전에 필요한 내용을 저장하세요.

TV 소리가 내장 마이크에 들어오면 같은 문장이 두 채널에 나타날 수 있습니다. 두 채널의 전사 문장이 같고 시간대가 가까우면 온라인 채널을 우선하지만, 인식 결과가 다르면 중복이 남을 수 있습니다. 실제 회의 전에 가장 먼 5m 자리에서 이름, 날짜, 숫자를 말해 보고 음질을 확인하세요.
