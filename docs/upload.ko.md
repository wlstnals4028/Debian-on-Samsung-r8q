# GitHub 업로드 안내

[English](upload.en.md) · [한국어](upload.ko.md) · [README](../README.ko.md)

먼저 준비된 ZIP을 해제합니다. `r8q-debian-github` 폴더 **안의 내용**을 올려 `README.md`, `docs`, `patches`, `sources`, `templates`가 저장소 루트에 오도록 합니다. ZIP 파일 하나만 올리면 GitHub에서 프로젝트 문서가 바로 표시되지 않습니다.

## 브라우저로 업로드

1. 자신의 GitHub 계정에 저장소를 만듭니다. 처음 가져오는 경우 자동 README·라이선스·gitignore 생성 옵션은 비워 둡니다.
2. 파일 업로드 화면을 엽니다. 기존 저장소에서는 **Add file → Upload files**를 선택합니다.
3. 압축 해제한 파일과 폴더를 끌어 넣습니다. 미리보기에서 `README.md`가 루트에 있고 하위 폴더 구조가 유지되는지 확인합니다.
4. 변경 내용을 검토하고 해당 저장소의 방식에 따라 커밋합니다.

브라우저 파일 선택기에서 `.gitignore`와 `.gitattributes`가 숨겨질 수 있습니다. 빠졌다면 별도로 추가하거나 Git으로 가져옵니다. 체크섬을 유지하도록 제공된 패치와 C 소스는 그대로 올립니다. 브라우저와 명령줄 업로드 방법은 [GitHub 공식 안내](https://docs.github.com/en/repositories/working-with-files/managing-files/adding-a-file-to-a-repository)를 참고하세요.

## Git으로 새 빈 저장소에 업로드

압축 해제한 **`r8q-debian-github` 폴더 안에서** 실행합니다. URL은 자신의 새 빈 GitHub 저장소 주소로 바꿉니다. 아래 명령은 저장소 소유자가 실행할 안내이며, 파일을 준비하면서 실행한 명령은 아닙니다.

```sh
git init -b main
git add .
git status --short
git diff --cached --stat
git commit -m "Document the r8q Debian native port"
git remote add origin https://github.com/YOUR-USERNAME/YOUR-REPOSITORY.git
git push -u origin main
```

Git 인증은 기존 설정을 사용합니다. 원격 저장소에 이미 커밋이 있다면 먼저 clone한 뒤 이 파일을 복사하고 변경 내용을 검토해 적절한 브랜치에서 커밋합니다. 가져오기를 위해 기존 기록을 강제 push로 덮어쓰지 않습니다.

## 업로드 후 확인

- 영어 README와 한국어 링크가 열리는지 확인합니다.
- 양쪽 상세 포팅 가이드의 상대 경로 링크를 확인합니다.
- boot 덤프, 펌웨어, rootfs 아카이브, 개인 키와 빌드 결과물은 올리지 않습니다. 제공된 `.gitignore`가 흔한 작업 파일을 제외합니다.
- `SHA256SUMS`는 준비된 현재 파일의 체크섬입니다. 의도적으로 파일을 수정하면 다시 생성합니다.
