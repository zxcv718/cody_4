# 요구사항 수행 내역서

대상 환경: Ubuntu 24.04 LTS VM  
방화벽: UFW  
앱 배치 경로: `/home/agent-admin/agent-app/agent-app`  
모니터링 스크립트: `/home/agent-admin/agent-app/bin/monitor.sh`  
보너스 과제: 제외

## 1. 수행 내역

- `openssh-server`, `ufw`, `acl`, `cron`, `procps`, `iproute2` 설치
- SSH 포트 `20022` 설정 및 root 원격 로그인 차단
- UFW 활성화, inbound `20022/tcp`, `15034/tcp`만 허용
- `agent-admin`, `agent-dev`, `agent-test` 계정 생성
- `agent-common`, `agent-core` 그룹 생성 및 역할 기반 그룹 할당
- `$AGENT_HOME`, `upload_files`, `api_keys`, `bin`, `/var/log/agent-app` 디렉토리와 ACL 설정
- 제공 바이너리 `agent-app` 배치 및 키 파일 `t_secret.key` 생성
- Bash 기반 `monitor.sh` 구현 및 `agent-admin` crontab 매분 실행 등록

## 2. 설정 및 명령어 기록

전체 자동 구성:

```bash
sudo ./scripts/setup-agent-env.sh
```

앱 실행:

```bash
./scripts/start-agent-app.sh
```

수동 모니터링:

```bash
sudo -u agent-admin env \
  AGENT_HOME=/home/agent-admin/agent-app \
  /home/agent-admin/agent-app/bin/monitor.sh
```

검증 명령 묶음:

```bash
sudo ./scripts/verify-agent-env.sh
```

## 3. 필수 증거 자료 체크리스트

### SSH

```bash
sudo sshd -T | grep -E '^(port|permitrootlogin)'
sudo ss -tulnp | grep ':20022'
```

결과:

```text
port 20022
permitrootlogin no
```

### UFW

```bash
sudo ufw status verbose
```

확인:

- `Status: active`
- `20022/tcp ALLOW IN`
- `15034/tcp ALLOW IN`
- 불필요한 inbound 허용 규칙 없음

### 계정/그룹

```bash
id agent-admin
id agent-dev
id agent-test
```

확인:

- `agent-admin`: `agent-common`, `agent-core` 포함
- `agent-dev`: `agent-common`, `agent-core` 포함
- `agent-test`: `agent-common` 포함, `agent-core` 미포함

### 디렉토리/권한/ACL

```bash
ls -ld /home/agent-admin/agent-app
ls -ld /home/agent-admin/agent-app/upload_files
ls -ld /home/agent-admin/agent-app/api_keys
ls -ld /home/agent-admin/agent-app/bin
ls -ld /var/log/agent-app
getfacl /home/agent-admin/agent-app/upload_files
getfacl /home/agent-admin/agent-app/api_keys
getfacl /home/agent-admin/agent-app/bin
getfacl /var/log/agent-app
```

확인:

- `upload_files`: group=`agent-common`, R/W 가능
- `api_keys`, `bin`, `/var/log/agent-app`: group=`agent-core`, R/W 가능
- `agent-test`는 `api_keys`, `bin`, `/var/log/agent-app` 접근 불가

### 앱 실행

```bash
sudo -u agent-admin env \
  AGENT_HOME=/home/agent-admin/agent-app \
  AGENT_PORT=15034 \
  AGENT_UPLOAD_DIR=/home/agent-admin/agent-app/upload_files \
  AGENT_KEY_PATH=/home/agent-admin/agent-app/api_keys/t_secret.key \
  AGENT_LOG_DIR=/var/log/agent-app \
  /home/agent-admin/agent-app/agent-app
```

결과:

```text
All Boot Checks Passed!
Agent READY
```

포트 확인:

```bash
sudo ss -ltnp | grep ':15034'
```

### monitor.sh 실행

```bash
sudo -u agent-admin env \
  AGENT_HOME=/home/agent-admin/agent-app \
  /home/agent-admin/agent-app/bin/monitor.sh
```

확인:

- 프로세스 `[OK]`
- 포트 `15034` `[OK]`
- CPU/MEM/DISK 출력
- 임계값 초과 시 `[WARNING]` 출력
- `/var/log/agent-app/monitor.log`에 로그 1줄 추가

### monitor.log 누적

```bash
sudo tail -n 10 /var/log/agent-app/monitor.log
```

예상 포맷:

```text
[YYYY-MM-DD HH:MM:SS] PID:... CPU:..% MEM:..% DISK_USED:..%
```

### cron 자동 실행

```bash
sudo -u agent-admin crontab -l
before=$(sudo wc -l < /var/log/agent-app/monitor.log)
sleep 70
after=$(sudo wc -l < /var/log/agent-app/monitor.log)
echo "before=$before after=$after"
sudo tail -n 10 /var/log/agent-app/monitor.log
```

확인:

- crontab에 매분 실행 등록
- 1분 후 `after` 값이 `before`보다 큼
- `monitor.log`에 새 라인이 자동 누적됨

### 로그 용량 관리

```bash
sudo truncate -s 10485761 /var/log/agent-app/monitor.log
sudo -u agent-admin env \
  AGENT_HOME=/home/agent-admin/agent-app \
  /home/agent-admin/agent-app/bin/monitor.sh
sudo ls -lh /var/log/agent-app/monitor.log*
```

확인:

- 10MB에서 1바이트라도 초과 시 기존 로그가 `monitor.log.1`로 회전
- 현재 로그와 회전 로그를 합쳐 최대 10개 파일 유지
