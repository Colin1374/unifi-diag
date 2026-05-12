#!/usr/bin/env bash
# Query UniFi MongoDB on UDR for diagnostic data
# Usage: ./collect-unifi-db.sh [COMMAND]
#
# Commands:
#   clients [--since DAYS]      Full client list (default --since 7; --since 0 = all)
#   clients-lean [--since DAYS] Compact: name|ip|mac6|ap|band (default --since 2)
#   client-stats IP             Per-client 5min stats (tx retries, signal, throughput)
#   wifi-events MAC [--since DAYS]  Connection/roam events (default --since 7, drops null-ap rows)
#   alarms                      Recent IDS/IPS alarms
#   topology                    Network infrastructure: devices, networks, WLANs
#   health                      Quick health: satisfaction scores, retry rates, channel util
#   all                         Run all queries (overview dump)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
UDR_HOST="udr"
MONGO="mongo --port 27117 --quiet"

TIMESTAMP=$(date +%Y%m%d-%H%M%S)

# Use heredocs for all mongo queries to avoid bash quoting issues with JS

cmd_clients() {
    local since_days="${1:-7}"
    local output="$PROJECT_DIR/summaries/unifi-clients-${TIMESTAMP}.txt"
    local since_epoch=0
    if [[ "$since_days" != "0" ]]; then
        since_epoch=$(( $(date +%s) - since_days * 86400 ))
    fi
    {
        echo "=== UniFi Client Database (since ${since_days}d, $(date +%F)) ==="
        echo "format: name|ip|mac|conn/radio|ap|oui|last"
        ssh "$UDR_HOST" "$MONGO ace" <<JSEOF
db.user.find(
  {last_seen:{\$gte:$since_epoch}},
  {hostname:1,name:1,mac:1,last_ip:1,oui:1,is_wired:1,
   last_uplink_name:1,last_radio:1,last_seen:1}
).sort({last_ip:1}).forEach(function(c) {
    var name = c.name || c.hostname || '(unknown)';
    var ip = c.last_ip || '-';
    var conn = c.is_wired ? 'wired' : 'wifi';
    var radio = c.last_radio || '-';
    var ap = c.last_uplink_name || '-';
    var oui = c.oui || '-';
    var last = c.last_seen ? new Date(c.last_seen*1000).toISOString().substr(0,16) : '-';
    print(name+'|'+ip+'|'+c.mac+'|'+conn+'/'+radio+'|'+ap+'|'+oui+'|'+last);
});
JSEOF
    } > "$output"
    echo "Written to: $output ($(wc -l < "$output") lines)"
    cat "$output"
}

cmd_clients_lean() {
    local since_days="${1:-2}"
    local output="$PROJECT_DIR/summaries/unifi-clients-lean-${TIMESTAMP}.txt"
    local since_epoch
    since_epoch=$(( $(date +%s) - since_days * 86400 ))
    {
        echo "=== Active clients (last ${since_days}d) ==="
        echo "format: name|ip|mac6|ap|band"
        ssh "$UDR_HOST" "$MONGO ace" <<JSEOF
db.user.find(
  {last_seen:{\$gte:$since_epoch}},
  {hostname:1,name:1,mac:1,last_ip:1,is_wired:1,last_uplink_name:1,last_radio:1}
).sort({last_ip:1}).forEach(function(c) {
    var name = c.name || c.hostname || '?';
    var ip = c.last_ip || '-';
    var mac6 = c.mac ? c.mac.substr(-8) : '-';
    var ap = c.last_uplink_name || '-';
    var band = c.is_wired ? 'wired' : (c.last_radio || '-');
    print(name+'|'+ip+'|'+mac6+'|'+ap+'|'+band);
});
JSEOF
    } > "$output"
    echo "Written to: $output ($(wc -l < "$output") lines)"
    cat "$output"
}

cmd_client_stats() {
    local target_ip="$1"
    local output="$PROJECT_DIR/summaries/unifi-client-stats-${target_ip}-${TIMESTAMP}.txt"

    # Resolve IP to MAC
    local mac
    mac=$(ssh "$UDR_HOST" "$MONGO ace" <<JSEOF
var u = db.user.findOne({last_ip:'$target_ip'});
if(u) print(u.mac); else print('NOT_FOUND');
JSEOF
    )
    mac=$(echo "$mac" | tr -d '[:space:]')
    if [[ "$mac" == "NOT_FOUND" || -z "$mac" ]]; then
        echo "ERROR: No client found with IP $target_ip"
        return 1
    fi

    {
        echo "=== Client Stats: $target_ip ($mac) ==="
        echo "Date: $(date)"
        echo ""

        echo "--- Last 12 intervals (1 hour of 5min stats) ---"
        ssh "$UDR_HOST" "$MONGO ace_stat" <<JSEOF
db.stat_5minutes.find(
  {oid:'$mac', o:'user'},
  {time:1,'ng-tx_retries':1,'na-tx_retries':1,'ng-wifi_tx_attempts':1,'na-wifi_tx_attempts':1,
   'ng-signal':1,'na-signal':1,'ng-satisfaction':1,'na-satisfaction':1,
   rx_rate_most_common:1,bytes:1,'ng-bytes':1,'na-bytes':1}
).sort({time:-1}).limit(12).forEach(function(s) {
    var t = new Date(s.time).toISOString().substr(11,8);
    var retries = s['ng-tx_retries'] || s['na-tx_retries'] || 0;
    var attempts = s['ng-wifi_tx_attempts'] || s['na-wifi_tx_attempts'] || 0;
    var retryPct = attempts > 0 ? ((retries/attempts)*100).toFixed(1) : '0';
    var signal = s['ng-signal'] || s['na-signal'] || '-';
    var satisfaction = s['ng-satisfaction'] || s['na-satisfaction'] || '-';
    var rxRate = s.rx_rate_most_common || '-';
    var bytes = 0;
    for(var k in s) { if(k.indexOf('-bytes') > -1 && typeof s[k] === 'number') bytes += s[k]; }
    print(t + ' | signal:' + (typeof signal === 'number' ? signal.toFixed(0) : signal) + 'dBm | retries:' + retryPct + '% (' + Math.round(retries) + '/' + Math.round(attempts) + ') | satisfaction:' + (typeof satisfaction === 'number' ? satisfaction.toFixed(0) : satisfaction) + ' | rxRate:' + rxRate + ' | bytes:' + Math.round(bytes));
});
JSEOF
        echo ""

        echo "--- Recent WiFi Events ---"
        ssh "$UDR_HOST" "$MONGO ace_stat" <<JSEOF
db.wifi_connectivity_event.find({client_mac:'$mac'}).sort({time:-1}).limit(20).forEach(function(e) {
    var t = new Date(e.time).toISOString().substr(0,19);
    var cls = e._class || '-';
    var ap = e.ap_mac || (e.to_endpoint ? e.to_endpoint.mac : '-');
    var rssi = e.rssi || (e.to_endpoint ? e.to_endpoint.rssi : '-');
    var ch = e.channel || (e.to_endpoint ? e.to_endpoint.channel : '-');
    var ok = e.successful ? 'OK' : 'FAIL';
    print(t + ' | ' + cls + ' | ' + ok + ' | AP:' + ap + ' | RSSI:' + rssi + ' | ch:' + ch);
});
JSEOF
    } > "$output"
    echo "Written to: $output ($(wc -l < "$output") lines)"
    cat "$output"
}

cmd_wifi_events() {
    local target_mac="$1"
    local since_days="${2:-7}"
    local output="$PROJECT_DIR/summaries/unifi-wifi-events-${TIMESTAMP}.txt"
    local since_ms=$(( ( $(date +%s) - since_days * 86400 ) * 1000 ))
    {
        echo "=== WiFi Events for $target_mac (last ${since_days}d) ==="
        ssh "$UDR_HOST" "$MONGO ace_stat" <<JSEOF
db.wifi_connectivity_event.find(
  {client_mac:'$target_mac', time:{\$gte:$since_ms},
   \$or:[{ap_mac:{\$exists:true,\$ne:null}},{to_endpoint:{\$exists:true}}]},
  {time:1,_class:1,successful:1,ap_mac:1,channel:1,rssi:1,radio_band:1,
   from_endpoint:1,to_endpoint:1,deltas:1}
).sort({time:-1}).limit(80).forEach(function(e) {
    var t = new Date(e.time).toISOString().substr(0,19);
    var cls = (e._class||'').replace(/^WIFI_/,'');
    var ok = e.successful ? 'OK' : 'FAIL';
    if(cls === 'ROAMING') {
        var f = e.from_endpoint||{}, to = e.to_endpoint||{};
        print(t+' ROAM '+ok+' '+(f.mac||'?').substr(-5)+'/ch'+(f.channel||'?')+'/'+(f.rssi||'?')
              +' -> '+(to.mac||'?').substr(-5)+'/ch'+(to.channel||'?')+'/'+(to.rssi||'?'));
    } else if(cls === 'CONNECTION') {
        var d = e.deltas||{};
        var dhcp = d.DHCP ? (d.DHCP/1000).toFixed(1)+'s' : '-';
        var wpa = d.WPA_AUTHENTICATION ? (d.WPA_AUTHENTICATION/1000).toFixed(1)+'s' : '-';
        print(t+' CONN '+ok+' ap:'+(e.ap_mac||'?').substr(-5)+' ch:'+(e.channel||'?')
              +' rssi:'+(e.rssi||'?')+' wpa:'+wpa+' dhcp:'+dhcp);
    } else {
        print(t+' '+cls+' '+ok+' ap:'+(e.ap_mac||'?').substr(-5)+' ch:'+(e.channel||'?')+' rssi:'+(e.rssi||'?'));
    }
});
JSEOF
    } > "$output"
    echo "Written to: $output ($(wc -l < "$output") lines)"
    cat "$output"
}

cmd_alarms() {
    local output="$PROJECT_DIR/summaries/unifi-alarms-${TIMESTAMP}.txt"
    {
        echo "=== Recent Alarms/IDS Events ==="
        echo "Date: $(date)"
        echo ""
        ssh "$UDR_HOST" "$MONGO ace" <<'JSEOF'
db.alarm.find().sort({timestamp:-1}).limit(30).forEach(function(a) {
    var t = new Date(a.timestamp * 1000).toISOString().substr(0,19);
    var cat = (a.ubnt && a.ubnt.ubnt_category) || a.event_type || '-';
    var src = a.src_ip || '-';
    var dst = a.dest_ip || '-';
    var port = a.dest_port || '-';
    var proto = a.proto || '-';
    var msg = (a.ubnt && a.ubnt.description) || a.msg || '-';
    var iface = a.in_iface || '-';
    print(t + ' | ' + cat + ' | ' + proto + ' ' + src + ' -> ' + dst + ':' + port + ' | ' + iface + ' | ' + msg);
});
JSEOF
    } > "$output"
    echo "Written to: $output ($(wc -l < "$output") lines)"
    cat "$output"
}

cmd_topology() {
    local output="$PROJECT_DIR/summaries/unifi-topology-${TIMESTAMP}.txt"
    {
        echo "=== Network Topology ==="
        echo "Date: $(date)"
        echo ""

        echo "--- UniFi Devices ---"
        ssh "$UDR_HOST" "$MONGO ace" <<'JSEOF'
db.device.find({},{name:1,model:1,type:1,ip:1,mac:1,version:1,uptime:1}).forEach(function(d) {
    print(d.type + ' | ' + (d.name||'-') + ' | ' + d.model + ' | ' + d.ip + ' | ' + d.mac + ' | fw:' + (d.version||'-'));
});
JSEOF
        echo ""

        echo "--- Networks/VLANs ---"
        ssh "$UDR_HOST" "$MONGO ace" <<'JSEOF'
db.networkconf.find({},{name:1,purpose:1,vlan:1,subnet:1,dhcpd_start:1,dhcpd_stop:1,dhcpd_enabled:1}).forEach(function(n) {
    print((n.name||'-') + ' | purpose:' + (n.purpose||'-') + ' | vlan:' + (n.vlan||'none') + ' | DHCP:' + (n.dhcpd_start||'-') + '-' + (n.dhcpd_stop||'-'));
});
JSEOF
        echo ""

        echo "--- WLANs ---"
        ssh "$UDR_HOST" "$MONGO ace" <<'JSEOF'
db.wlanconf.find({},{name:1,enabled:1,security:1,wpa_mode:1,is_guest:1,networkconf_id:1}).forEach(function(w) {
    print((w.name||'-') + ' | enabled:' + w.enabled + ' | ' + (w.security||'-') + '/' + (w.wpa_mode||'-') + ' | guest:' + (w.is_guest||false));
});
JSEOF
    } > "$output"
    echo "Written to: $output ($(wc -l < "$output") lines)"
    cat "$output"
}

cmd_health() {
    local output="$PROJECT_DIR/summaries/unifi-health-${TIMESTAMP}.txt"
    {
        echo "=== Network Health Snapshot ==="
        echo "Date: $(date)"
        echo ""

        echo "--- Client Satisfaction (last 5min, per AP) ---"
        ssh "$UDR_HOST" "$MONGO ace_stat" <<'JSEOF'
db.stat_5minutes.find({o:'ap'}).sort({time:-1}).limit(6).forEach(function(s) {
    var t = new Date(s.time).toISOString().substr(11,8);
    var ap = s.oid || '-';
    var sat = s['user-satisfaction'] || s['ng-satisfaction'] || s['na-satisfaction'] || '-';
    var clients = s['user-num_sta'] || s.num_sta || '-';
    var txRetries = s['ng-tx_retries'] || s['na-tx_retries'] || 0;
    var txAttempts = s['ng-wifi_tx_attempts'] || s['na-wifi_tx_attempts'] || 1;
    var retryPct = ((txRetries/txAttempts)*100).toFixed(1);
    print(t + ' | AP:' + ap + ' | satisfaction:' + (typeof sat === 'number' ? sat.toFixed(0) : sat) + ' | clients:' + clients + ' | retry:' + retryPct + '%');
});
JSEOF
        echo ""

        echo "--- Downtime Events (last 10) ---"
        ssh "$UDR_HOST" "$MONGO ace_stat" <<'JSEOF'
db.downtime.find().sort({timestamp:-1}).limit(10).forEach(function(d) {
    var ts = new Date(d.timestamp.toNumber()).toISOString().substr(0,19);
    var dur = d.downtime ? d.downtime + 's' : '-';
    var wan = d.wan_networkgroup || '-';
    print(ts + ' | ' + wan + ' | downtime:' + dur);
});
JSEOF
    } > "$output"
    echo "Written to: $output ($(wc -l < "$output") lines)"
    cat "$output"
}

# Parse: --since N as a trailing flag for any command that accepts it
SINCE=""
ARGS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --since) SINCE="$2"; shift 2 ;;
        *) ARGS+=("$1"); shift ;;
    esac
done
set -- "${ARGS[@]:-}"

CMD="${1:-help}"
shift || true

case "$CMD" in
    clients)       cmd_clients "${SINCE:-7}" ;;
    clients-lean)  cmd_clients_lean "${SINCE:-2}" ;;
    client-stats)  cmd_client_stats "${1:?Usage: client-stats IP}" ;;
    wifi-events)   cmd_wifi_events "${1:?Usage: wifi-events MAC [--since DAYS]}" "${SINCE:-7}" ;;
    alarms)        cmd_alarms ;;
    topology)      cmd_topology ;;
    health)        cmd_health ;;
    all)
        cmd_topology
        echo ""; echo "========================"; echo ""
        cmd_clients "${SINCE:-7}"
        echo ""; echo "========================"; echo ""
        cmd_health
        echo ""; echo "========================"; echo ""
        cmd_alarms
        ;;
    *)
        echo "Usage: $0 {clients|clients-lean|client-stats IP|wifi-events MAC|alarms|topology|health|all} [--since DAYS]"
        exit 1
        ;;
esac
