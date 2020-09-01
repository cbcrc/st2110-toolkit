#!/bin/bash

usage(){
    echo "$0 interprets tcpdump-like parameters and passes them to
    dpdk utilties, i.e. tespmd and dpdk-pdump
Usage:
    $0 -i interface0 [-i interface1] -w file.pcap [-G <secondes>] [-v[v]] [ filter expr ]

Exples:
    $0 -i enp1s0f0 -w /tmp/single.pcap -G 1 dst 225.192.10.1
    $0 -vv -i enp1s0f0 -i enp1s0f1 -w /tmp/dual.pcap -G 1
    " >&2
}

timeout=2
verbose=0
dual_port=0
testpmd_log=/tmp/dpdk-testpmd.log
iface=""

dpdk_log(){
    echo "dpdk-capture: $@"
}

dpdk_log "Parse args: ------------------------------------------ "

#  typical cmdline to be translated:
#  $ tcpdump -i interfaceName --time-stamp-precision=nano \
#   -j adapter_unsynced\--snapshot-length=N -v -w pcap -G 2 -W 1 \
#   dst 192.168.1.1 or dst 192.168.1.2
while getopts ":i:w:G:W:v" o; do
    case "${o}" in
        i | interface)
            if [ ! -z "$iface" ]; then
                dual_port=1
            fi

            iface="$iface ${OPTARG}"
            ;;
        j)
            ;;
        #-)
        #    case ${OPTARG} in
        #        time-stamp-precision*)
        #            ;;
        #        snapshot-length*)
        #            ;;
        #    esac
        #    ;;
        w)
            pcap=${OPTARG}
            ;;
        G)
            timeout=${OPTARG}
            ;;
        W)
            #ignore file number
            ;;
        v)
            verbose=1
            ;;
        vv)
            verbose=1
            set -x
            ;;
        *)
            dpdk_log  "unsupported option ${o}"
            usage
            exit 1
            ;;
    esac
done

shift $((OPTIND-1))

if [ -z "$iface" -o -z "$pcap" ]; then
    dpdk_log "Missing argument"
    usage
    exit 1
fi

filter=$@
IPs=$(echo $filter | sed 's/dst//g; s/or//g' | tr -s ' ' '\n')
pcap=$(echo $pcap | sed 's/\(.*\)\.pcap/\1/')

dpdk_log "iface: $iface
pcap: $pcap
filter: $filter
dual_port: $dual_port
timeout: $timeout"


dpdk_log "Checking interface: $i ------------------------------------------ "

for i in $iface; do
    if [ ! -d /sys/class/net/$i ]; then
        dpdk_log "$i doesn\'t exist, exit."
        exit 1
    fi
    if [ $(cat /sys/class/net/$i/operstate) != "up" ]; then
        dpdk_log "$i is not up, exit."
        exit 1
    fi
    if [ $verbose -eq 1 ]; then
        dpdk_log "Devices"
        dpdk-devbind --status | grep "if=$i"
        #0000:01:00.0 'MT27800 Family [ConnectX-5] 1017' if=enp1s0f0 drv=mlx5_core unused= *Active*
    fi
done

dpdk_log "Joining mcast: $IPs ------------------------------------------ "
for i in $iface; do
    if [ ! -z "$filter" ]; then

        if ! smcroutectl show > /dev/null; then
            smcrouted
        fi

        for ip in $IPs; do
            smcroutectl join $i $ip
            if ! netstat -ng | grep -q "$i.*$ip"; then
                dpdk_log "Can\'t joint $ip"
            fi
        done

        if [ $verbose -eq 1 ]; then
            netstat -ng | grep $i
        fi
    else
        dpdk_log "No filter"
    fi
done

# dpdk
dpdk_log "Capturing------------------------------------------"

dpdk_log "Start PMD"
pci=$(dpdk-devbind --status | grep "ConnectX" | \
    cut -d ' ' -f1 | sed 's/\(.*\)/ -w \1 /' | tr -d '\n')
# create a detached session to run PMD server
screen -dmS testpmd -L -Logfile $testpmd_log \
    testpmd $pci -l 0-3 -n 4 -- --enable-rx-timestamp --forward-mode=rxonly

sleep 3

# TODO: compile and pass a filter

#pkt_rx_start=$(ethtool -S $i | grep rx_packets: | sed  's/.*: \(.*\)/\1/')
#pkt_drop_start=$(ethtool -S $i | grep rx_out_of_buffer: | sed  's/.*: \(.*\)/\1/')

dpdk_log "Start pdump"
if [ $dual_port -eq 1 ]; then
    args="-- --pdump port=0,queue=0,rx-dev=$pcap-0.pcap --pdump port=1,queue=0,rx-dev=$pcap-1.pcap"
else
    port=$(echo $iface | sed 's/.*\(.\)/\1/')
    args="-- --pdump port=$port,queue=*,rx-dev=$pcap-$port.pcap"
fi
dpdk-pdump $args 2>&1 &

sleep $timeout

dpdk_log "Stop testpmd / pdump -------------------------------------"
# send a SGINT after after timeout
killall -s 2 dpdk-pdump

# send carriage return to stop testpmd
screen -S testpmd -X stuff "
"
if [ $verbose -eq 1 ]; then
    cat $testpmd_log
fi
rm $testpmd_log

for i in $iface; do
    if [ ! -z "$filter" ]; then
        dpdk_log "Leaving mcast ------------------------------------------"
        for ip in $IPs; do
            smcroutectl leave $i $ip
        done
    fi

    port=$(echo $i | sed 's/.*\(.\)/\1/')
    if [ $verbose -eq 1 ]; then
        dpdk_log "pcapinfo port $port"
        capinfos $pcap-$port.pcap
    fi
done

#pkt_rx_end=$(ethtool -S $i | grep rx_packets: | sed  's/.*: \(.*\)/\1/')
#pkt_drop_end=$(ethtool -S $i | grep rx_out_of_buffer: | sed  's/.*: \(.*\)/\1/')
#dpdk_log "rx: $(echo "$pkt_rx_end - $pkt_rx_start" | bc)"
#dpdk_log "drop: $(echo "$pkt_drop_end - $pkt_drop_start" | bc)"

if [ $dual_port -eq 1 ]; then
    mergecap -w $pcap.pcap -F nsecpcap $pcap-0.pcap $pcap-1.pcap
    echo $(ls $pcap-[01].pcap) merged into $pcap.pcap
    rm -f $pcap-0.pcap $pcap-1.pcap
else
    port=$(echo $iface | sed 's/.*\(.\)/\1/')
    mv $pcap-$port.pcap $pcap.pcap
fi