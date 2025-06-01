#!/bin/bash

# 智能TCP参数优化脚本（BBR + BBR2 + 自动调度器 + 延迟追踪 + 日志记录）
# Made by Meeta_Li

REQUIRED_PKGS=(speedtest-cli iperf3 bc iproute2 curl)
echo "检查依赖..."
for pkg in "${REQUIRED_PKGS[@]}"; do
  if ! dpkg -s "$pkg" >/dev/null 2>&1; then
    echo "安装 $pkg..."
    sudo apt update && sudo apt install -y "$pkg"
  fi
done

check_bbr_status() {
  echo "检查 BBR 启用状态..."
  CURRENT_CC=$(sysctl net.ipv4.tcp_congestion_control | awk '{print $3}')
  AVAILABLE_CC=$(sysctl net.ipv4.tcp_available_congestion_control)
  if echo "$AVAILABLE_CC" | grep -q bbr; then
    echo "检测到系统支持 BBR"
    if [ "$CURRENT_CC" != "bbr" ] && [ "$CURRENT_CC" != "bbr2" ]; then
      echo "当前未启用 BBR，尝试启用..."
      echo "net.core.default_qdisc=fq" | sudo tee -a /etc/sysctl.conf > /dev/null
      echo "net.ipv4.tcp_congestion_control=bbr" | sudo tee -a /etc/sysctl.conf > /dev/null
      sudo sysctl -p
    else
      echo "BBR 已启用 ($CURRENT_CC)"
    fi
  else
    echo "未检测到可用的 BBR/BBR2。建议升级内核后重试。"
  fi
}

ping_test() {
  local ip=$1
  local avg_rtt=$(ping -c 4 -W 1 "$ip" | awk -F'/' '/rtt/ {print $5}' | awk '{print int($1)}')
  echo "$avg_rtt"
}

check_bbr_status

if [ -f ./vps_type.conf ]; then
  source ./vps_type.conf
else
  echo "选择VPS类型: 1=中转机(relay), 2=落地机(proxy), 3=中转+落地机(mixed)"
  read -p "输入 (1/2/3): " TYPE_SELECT
  case "$TYPE_SELECT" in
    1) VPS_TYPE="relay";;
    2) VPS_TYPE="proxy";;
    3) VPS_TYPE="mixed";;
    *) VPS_TYPE="mixed";;
  esac
fi

read -p "输入 iperf3 测试服务器 IP（空格分隔）: " -a IPERF_SERVERS

CPU_CORES=$(nproc)
CPU_MHZ=$(awk -F: '/cpu MHz/ {print $2; exit}' /proc/cpuinfo | awk '{print int($1)}')
MEM_MB=$(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo)
echo "CPU: $CPU_CORES 核心 @ ${CPU_MHZ}MHz, 可用内存: ${MEM_MB}MB"

KERNEL_RMEM_MAX=$(cat /proc/sys/net/core/rmem_max)
KERNEL_WMEM_MAX=$(cat /proc/sys/net/core/wmem_max)
SAFE_MAX=$((KERNEL_RMEM_MAX<KERNEL_WMEM_MAX ? KERNEL_RMEM_MAX : KERNEL_WMEM_MAX))

KERNEL_VERSION=$(uname -r | cut -d'-' -f1)
BBR2_SUPPORTED=0
if [[ $(echo -e "$KERNEL_VERSION\n5.9" | sort -V | head -n1) == "5.9" ]]; then
  if sysctl net.ipv4.tcp_available_congestion_control | grep -q bbr2; then
    BBR2_SUPPORTED=1
  fi
fi

CAKE_SUPPORTED=0
FQC_SUPPORTED=0
if tc qdisc add dev lo root handle 1: cake 2>/dev/null; then
  CAKE_SUPPORTED=1; tc qdisc del dev lo root 2>/dev/null
fi
if tc qdisc add dev lo root handle 1: fq_codel 2>/dev/null; then
  FQC_SUPPORTED=1; tc qdisc del dev lo root 2>/dev/null
fi

run_speedtest() {
  echo "运行 Speedtest..."
  RESULT=$(speedtest-cli --simple)
  echo "$RESULT"
  DL=$(echo "$RESULT" | grep Download | awk '{print int($2)}')
  UL=$(echo "$RESULT" | grep Upload | awk '{print int($2)}')
}

test_tcp_retransmission() {
  local server=$1
  echo "iperf3 测试 -> $server"
  DL_SPEED=$(iperf3 -c "$server" -t 10 -R | awk '/receiver/{print int($(NF-1))}')
  UL_SPEED=$(iperf3 -c "$server" -t 10 | awk '/sender/{print int($(NF-1))}')
  RETRANS=$(ss -ti dst "$server" | grep -Po 'retrans:\d+/\K\d+' | awk '{sum+=$1} END{print sum+0}')
  SEGS_OUT=$(ss -ti dst "$server" | grep -Po 'segs_out:\K\d+' | awk '{sum+=$1} END{print sum+0}')
  RETRANS_RATE=0
  if [ "$SEGS_OUT" -gt 0 ]; then
    RETRANS_RATE=$(echo "scale=2; $RETRANS / $SEGS_OUT * 100" | bc)
  fi
  AVG_IPERF=$(( (DL_SPEED + UL_SPEED) / 2 ))
  PING_RTT=$(ping_test "$server")
  echo "UL: ${UL_SPEED}Mbps, DL: ${DL_SPEED}Mbps, AVG: ${AVG_IPERF}Mbps, RTT: ${PING_RTT}ms, 重传率: ${RETRANS_RATE}%"
}

adjust_tcp() {
  local bw=$1
  local loss=$2

  case "$VPS_TYPE" in
    relay)
      BUFFER=$((bw * 131072)); INIT_CWND=20; TIMEOUT=10;;
    proxy)
      BUFFER=$((bw * 262144)); INIT_CWND=30; TIMEOUT=7;;
    mixed)
      BUFFER=$((bw * 196608)); INIT_CWND=25; TIMEOUT=8;;
  esac

  MAX_BUFFER=$((MEM_MB * 1024 * 512))
  [ "$BUFFER" -gt "$MAX_BUFFER" ] && BUFFER=$MAX_BUFFER
  [ "$BUFFER" -gt "$SAFE_MAX" ] && BUFFER=$SAFE_MAX

  if (( $(echo "$loss > 3" | bc -l) )); then
    BUFFER=$((BUFFER / 4)); INIT_CWND=$((INIT_CWND / 2))
  elif (( $(echo "$loss > 1" | bc -l) )); then
    BUFFER=$((BUFFER / 2))
  fi

  CONGESTION="bbr"
  [ "$BBR2_SUPPORTED" -eq 1 ] && CONGESTION="bbr2"

  if [ "$bw" -lt 150 ] && [ "$CAKE_SUPPORTED" -eq 1 ] && [ "$CPU_CORES" -ge 2 ] && [ "$CPU_MHZ" -ge 1800 ]; then
    QDISC="cake"
  elif [ "$bw" -lt 300 ] && [ "$FQC_SUPPORTED" -eq 1 ]; then
    QDISC="fq_codel"
  else
    QDISC="fq"
  fi

sudo tee /etc/sysctl.conf > /dev/null <<EOF
net.core.default_qdisc=$QDISC
net.core.netdev_max_backlog=8192
net.core.somaxconn=8192
net.core.rmem_max=$BUFFER
net.core.wmem_max=$BUFFER
net.ipv4.tcp_rmem=4096 87380 $BUFFER
net.ipv4.tcp_wmem=4096 65536 $BUFFER
net.ipv4.tcp_congestion_control=$CONGESTION
net.ipv4.tcp_fin_timeout=$TIMEOUT
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_tw_reuse=1
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_max_syn_backlog=8192
net.ipv4.tcp_max_tw_buckets=262144
net.ipv4.ip_local_port_range=10240 65535
EOF

[ -f /proc/sys/net/ipv4/tcp_init_cwnd ] && \
  echo "net.ipv4.tcp_init_cwnd=$INIT_CWND" | sudo tee -a /etc/sysctl.conf > /dev/null

sudo sysctl -p
}

FINAL_SCORE=0
FINAL_PARAMS=""

for round in {1..3}; do
  echo "第 $round 轮测速..."
  run_speedtest
  for server in "${IPERF_SERVERS[@]}"; do
    test_tcp_retransmission "$server"
    case "$VPS_TYPE" in
      relay) REF_BW=$UL;;
      proxy) REF_BW=$DL;;
      mixed) REF_BW=$(( (UL + DL) / 2 ));;
    esac
    PING_RTT=$(ping_test "$server")
    [ "$REF_BW" -gt 10000 ] && echo "跳过异常值 $REF_BW Mbps" && continue
    SCORE=$(echo "$REF_BW - $RETRANS_RATE * 10 - $PING_RTT / 10" | bc)
    adjust_tcp "$REF_BW" "$RETRANS_RATE"
    if (( $(echo "$SCORE > $FINAL_SCORE" | bc -l) )); then
      FINAL_SCORE=$SCORE
      FINAL_PARAMS="模式: $VPS_TYPE | 带宽: ${REF_BW}Mbps | RTT: ${PING_RTT}ms | 重传: ${RETRANS_RATE}% | 缓冲: $BUFFER | cwnd: $INIT_CWND | timeout: $TIMEOUT | 拥塞: $CONGESTION | 调度器: $QDISC | CPU: ${CPU_CORES}核 @${CPU_MHZ}MHz"
    fi
  done
  [ "$round" -lt 3 ] && echo "等待2分钟..." && sleep 120
done

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
echo -e "\n最佳TCP配置：$FINAL_PARAMS"
echo "$FINAL_PARAMS" > ~/best_tcp_params_$TIMESTAMP.log
