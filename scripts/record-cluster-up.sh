#!/usr/bin/env bash
set -euo pipefail

# 결과 파일 이름
CAST_FILE="cluster_up_provisioning.cast"
GIF_FILE="cluster_up_provisioning.gif"
MP4_FILE="cluster_up_provisioning.mp4"

# 출력 디렉토리 (홈에 저장)
OUTPUT_DIR="$HOME/recordings"
mkdir -p "$OUTPUT_DIR"

# ansible 작업 디렉토리 (실제 repo 위치)
ANSIBLE_DIR="/mnt/c/Users/melan/ktcloud-troica/msa-provisioning/ansible"
SCRIPTS_DIR="/mnt/c/Users/melan/ktcloud-troica/msa-provisioning/scripts"
AWS_VERIFY_SCRIPT="$SCRIPTS_DIR/verify-aws-resources.sh"

# 사전 검증
if [ ! -d "$ANSIBLE_DIR" ]; then
  echo "error: ansible 디렉토리를 찾을 수 없습니다: $ANSIBLE_DIR" >&2
  exit 1
fi

if [ ! -f "$ANSIBLE_DIR/inventory.ini" ]; then
  echo "error: inventory.ini 가 없습니다: $ANSIBLE_DIR/inventory.ini" >&2
  exit 1
fi

if [ ! -f "$ANSIBLE_DIR/main.yaml" ]; then
  echo "error: main.yaml 이 없습니다: $ANSIBLE_DIR/main.yaml" >&2
  exit 1
fi

if [ ! -f "$ANSIBLE_DIR/verify-cluster.yaml" ]; then
  echo "error: verify-cluster.yaml 이 없습니다: $ANSIBLE_DIR/verify-cluster.yaml" >&2
  exit 1
fi

if [ ! -f "$AWS_VERIFY_SCRIPT" ]; then
  echo "error: verify-aws-resources.sh 가 없습니다: $AWS_VERIFY_SCRIPT" >&2
  exit 1
fi

# AWS CLI + 자격증명 사전 확인 (녹화 중 실패 방지)
if ! command -v aws >/dev/null 2>&1; then
  echo "error: aws CLI not found in PATH" >&2
  exit 1
fi
if ! aws sts get-caller-identity >/dev/null 2>&1; then
  echo "error: AWS credentials not configured (aws sts get-caller-identity failed)" >&2
  exit 1
fi

# ANSI 색상 강제 (ansible 의 초록/빨강 표시 보존)
export ANSIBLE_FORCE_COLOR=true

# 필수 도구 확인
for bin in asciinema agg ffmpeg ansible-playbook; do
  if ! command -v "$bin" >/dev/null 2>&1; then
    echo "error: '$bin' not found in PATH" >&2
    exit 1
  fi
done

# 출력 디렉토리로 이동 (cast/gif/mp4 파일이 여기에 저장됨)
cd "$OUTPUT_DIR"

# 기존 파일 제거
rm -f "$CAST_FILE" "$GIF_FILE" "$MP4_FILE"

echo ">>> 사전 검증 통과"
echo ">>> ansible 디렉토리: $ANSIBLE_DIR"
echo ">>> 결과 저장 위치: $OUTPUT_DIR/$MP4_FILE"
echo ""
echo ">>> [1/3] asciinema 녹화 시작"
echo ">>> 약 10~15분 소요됩니다. 종료까지 기다리세요."
echo ">>> 강제 종료가 필요하면 Ctrl-C 두 번 누르세요."
echo ""

# ansible-playbook 을 절대 경로로 실행
# bash -c 안에서 cd 후 명령 실행. cd 가 실패하면 set -e 로 즉시 종료
asciinema rec --idle-time-limit=2 \
  -c "bash -c 'set -e; bash $AWS_VERIFY_SCRIPT && cd $ANSIBLE_DIR && ansible-playbook -i inventory.ini main.yaml && ansible-playbook -i inventory.ini verify-cluster.yaml'" \
  "$CAST_FILE"

echo ""
echo ">>> [2/3] cast → GIF 변환 (이 단계도 시간 소요됩니다)"
agg --theme monokai --font-size 14 "$CAST_FILE" "$GIF_FILE"

echo ""
echo ">>> [3/3] GIF → MP4 변환 (10분/100MB 시연 영상 제약 고려)"
ffmpeg -y -i "$GIF_FILE" \
  -movflags faststart \
  -pix_fmt yuv420p \
  -vf "scale=trunc(iw/2)*2:trunc(ih/2)*2,fps=15" \
  -b:v 1200k \
  -maxrate 1500k \
  -bufsize 3000k \
  "$MP4_FILE"

# 중간 파일 정리
rm -f "$CAST_FILE" "$GIF_FILE"

echo ""
echo ">>> 완료: $OUTPUT_DIR/$MP4_FILE"
echo ">>> 파일 크기:"
ls -lh "$MP4_FILE"
echo ""
echo ">>> 영상 길이 확인:"
ffmpeg -i "$MP4_FILE" 2>&1 | grep "Duration"