#!/usr/bin/env bash
# Record ArgoCD platform/microservice sync + final pod & external probe state.
# Intended to be run AFTER record-cluster-up.sh, then the two MP4s are concat'd
# into a single demo video.
set -euo pipefail

# 결과 파일 이름
CAST_FILE="platform_sync.cast"
GIF_FILE="platform_sync.gif"
MP4_FILE="platform_sync.mp4"

# cluster-up 녹화와 concat할 때 사용
CLUSTER_UP_MP4="cluster_up_provisioning.mp4"
FINAL_MP4="cluster_up_full_demo.mp4"

# 출력 디렉토리 (홈에 저장) - record-cluster-up.sh와 동일
OUTPUT_DIR="$HOME/recordings"
mkdir -p "$OUTPUT_DIR"

# 절대 경로 (record-cluster-up.sh와 동일 패턴 유지)
ANSIBLE_DIR="/mnt/c/Users/melan/ktcloud-troica/msa-provisioning/ansible"
PLAYBOOK="$ANSIBLE_DIR/verify-platform-sync.yaml"

# 사전 검증
if [ ! -d "$ANSIBLE_DIR" ]; then
  echo "error: ansible 디렉토리를 찾을 수 없습니다: $ANSIBLE_DIR" >&2
  exit 1
fi

if [ ! -f "$ANSIBLE_DIR/inventory.ini" ]; then
  echo "error: inventory.ini 가 없습니다: $ANSIBLE_DIR/inventory.ini" >&2
  exit 1
fi

if [ ! -f "$PLAYBOOK" ]; then
  echo "error: verify-platform-sync.yaml 이 없습니다: $PLAYBOOK" >&2
  exit 1
fi

# ANSI 색상 강제
export ANSIBLE_FORCE_COLOR=true

# 필수 도구 확인
for bin in asciinema agg ffmpeg ansible-playbook; do
  if ! command -v "$bin" >/dev/null 2>&1; then
    echo "error: '$bin' not found in PATH" >&2
    exit 1
  fi
done

cd "$OUTPUT_DIR"

# 기존 중간 파일 제거 (최종 합본은 보존하지 않고 새로 만듦)
rm -f "$CAST_FILE" "$GIF_FILE" "$MP4_FILE" "$FINAL_MP4"

echo ">>> 사전 검증 통과"
echo ">>> ansible 디렉토리: $ANSIBLE_DIR"
echo ">>> 결과 저장 위치: $OUTPUT_DIR/$MP4_FILE"
echo ""
echo ">>> [1/3] asciinema 녹화 시작 (ArgoCD sync polling - 5~15분 소요)"
echo ">>> 강제 종료가 필요하면 Ctrl-C 두 번 누르세요."
echo ""

# polling은 sleep이 길어서 idle-time-limit=2로 컷
asciinema rec --idle-time-limit=2 \
  -c "bash -c 'set -e; cd $ANSIBLE_DIR && ansible-playbook -i inventory.ini verify-platform-sync.yaml'" \
  "$CAST_FILE"

echo ""
echo ">>> [2/3] cast → GIF 변환"
agg --theme monokai --font-size 14 "$CAST_FILE" "$GIF_FILE"

echo ""
echo ">>> [3/3] GIF → MP4 변환 (10분/100MB 제약 고려)"
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
echo ">>> platform sync 녹화 완료: $OUTPUT_DIR/$MP4_FILE"
ls -lh "$MP4_FILE"
ffmpeg -i "$MP4_FILE" 2>&1 | grep "Duration"

# cluster-up MP4와 이어붙이기는 별도 concat-demo.sh 로 분리됨.
# 두 녹화의 asciinema 출력 해상도가 터미널 폭에 따라 달라지는 경우가
# 있어서 -c copy 무손실 concat 가 항상 가능하다고 가정할 수 없음.
# concat-demo.sh 는 1280x640 캔버스에 둘 다 pad + re-encode 하므로
# 해상도 불일치에도 안전하다.
SCRIPTS_DIR="/mnt/c/Users/melan/ktcloud-troica/msa-provisioning/scripts"
CONCAT_SCRIPT="$SCRIPTS_DIR/concat-demo.sh"

if [ -f "$CLUSTER_UP_MP4" ] && [ -f "$CONCAT_SCRIPT" ]; then
  echo ""
  echo ">>> cluster-up + platform-sync 이어붙이기 (concat-demo.sh)"
  bash "$CONCAT_SCRIPT"
else
  echo ""
  if [ ! -f "$CLUSTER_UP_MP4" ]; then
    echo ">>> 참고: $CLUSTER_UP_MP4 이 없어 concat 단계 건너뜀."
    echo ">>>       record-cluster-up.sh 를 먼저 실행한 뒤 다시 돌리면 합본이 만들어집니다."
  fi
  if [ ! -f "$CONCAT_SCRIPT" ]; then
    echo ">>> 참고: $CONCAT_SCRIPT 가 없어 concat 단계 건너뜀."
  fi
fi
