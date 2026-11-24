FROM kalilinux/kali-rolling:latest

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    man-db \
    groff-base \
    less \
    nmap \
    ncat \
    ndiff \
    arp-scan \
    arping \
    fping \
    hping3 \
    tshark \
    tcpdump \
    ngrep \
    p0f \
    miniupnpc \
    avahi-utils \
    dnsutils \
    whois \
    traceroute \
    mtr-tiny \
    sslscan \
    whatweb \
    snmp \
    smbclient \
    socat \
    conntrack \
    iproute2 \
    nftables \
    iptables \
    iputils-ping \
    ndisc6 \
    netcat-openbsd \
    curl \
    jq \
    python3 \
    python3-scapy \
    ca-certificates \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# WSL2-aware smart nmap wrapper:
# 1. Preserves root privileges (never passes --unprivileged) so -O (OS fingerprinting) and raw ARP MAC lookup work.
# 2. Defaults TCP scans to -sT (TCP connect) so Hyper-V's virtual switch never drops raw SYN frames.
# 3. Accelerates -sU + -sV (UDP version scans) and -p- (65k port scans) against silent/filtered IoT hosts.
RUN cat << 'EOF' > /usr/local/bin/nmap && chmod +x /usr/local/bin/nmap
#!/usr/bin/env bash
args=()
has_tcp_scan=0; has_udp_scan=0; has_sv=0; has_ver_int=0; has_all_ports=0; has_min_rate=0; has_max_retries=0; has_timing=0; is_ping_or_list=0
for arg in "$@"; do
    case "$arg" in
        -sS) args+=("-sT"); has_tcp_scan=1 ;;
        -sT|-sA|-sW|-sM|-sN|-sF|-sX) args+=("$arg"); has_tcp_scan=1 ;;
        -sU) args+=("$arg"); has_udp_scan=1 ;;
        -sn|-sP|-sL) args+=("$arg"); is_ping_or_list=1 ;;
        -sV|-A) args+=("$arg"); has_sv=1 ;;
        --version-intensity*|--version-light|--version-all) args+=("$arg"); has_ver_int=1 ;;
        -p-|-p1-65535|-p0-65535) args+=("$arg"); has_all_ports=1 ;;
        --min-rate*) args+=("$arg"); has_min_rate=1 ;;
        --max-retries*) args+=("$arg"); has_max_retries=1 ;;
        -T[0-5]) args+=("$arg"); has_timing=1 ;;
        --unprivileged) ;;
        *) args+=("$arg") ;;
    esac
done
extra=()
[ "$is_ping_or_list" -eq 0 ] && [ "$has_tcp_scan" -eq 0 ] && [ "$has_udp_scan" -eq 0 ] && extra+=("-sT")
[ "$has_udp_scan" -eq 1 ] && [ "$has_sv" -eq 1 ] && [ "$has_ver_int" -eq 0 ] && extra+=("--version-intensity" "0")
if [ "$has_udp_scan" -eq 1 ] || [ "$has_all_ports" -eq 1 ]; then
    [ "$has_timing" -eq 0 ] && extra+=("-T4")
    [ "$has_max_retries" -eq 0 ] && extra+=("--max-retries" "1")
fi
[ "$has_all_ports" -eq 1 ] && [ "$has_min_rate" -eq 0 ] && extra+=("--min-rate" "1500")
exec /usr/bin/nmap "${extra[@]}" "${args[@]}"
EOF

WORKDIR /tyler
# Pre-create a valid 24-byte empty PCAP global header for zero-latency tshark -Y display filter syntax validation
RUN python3 -c "from pathlib import Path; Path('/tmp/.tyler_empty.pcap').write_bytes(b'\xd4\xc3\xb2\xa1\x02\x00\x04\x00\x00\x00\x00\x00\x00\x00\x00\x00\xff\xff\x00\x00\x01\x00\x00\x00')"
CMD ["bash", "-c", "python3 -c \"from pathlib import Path; p=Path('/tmp/.tyler_empty.pcap'); p.exists() or p.write_bytes(b'\\xd4\\xc3\\xb2\\xa1\\x02\\x00\\x04\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\xff\\xff\\x00\\x00\\x01\\x00\\x00\\x00')\" && exec sleep infinity"]

