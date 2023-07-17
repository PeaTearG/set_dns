#!/bin/bash
#set -ex

# [--reset] [--hash] [ --servers ... ] --domains ...

D=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd)

if [[ -f /etc/appgate.conf && "$D" == "/Library/Application Support/AppGate/osx" ]]; then
    dns_script=$(cat /etc/appgate.conf | tr '\t' ' '| sed -e 's/^[ ]*//' -e 's/[ ]*$//' -e 's/[ ]*=[ ]*/=/' | grep "^dns_script=" | cut -d = -f2)
    if [[ -x "$dns_script" ]]; then
        exec "$dns_script" "$@"
    fi
fi

LEGACY=no

function usage() {
    echo "ERROR: wrong arguments"
    exit 1
}

function flush_dns_cache {
    # Wait a bit and then clean cache
    sleep 3

    if [ -f $ROOT/usr/bin/dscacheutil ]; then
        $ROOT/usr/bin/dscacheutil -flushcache
    fi

    if [ -f /usr/sbin/discoveryutil ]; then
        $ROOT/usr/sbin/discoveryutil udnsflushcache
        $ROOT/usr/sbin/discoveryutil mdnsflushcache
    fi

    killall -HUP mDNSResponder
    return
}

function clear_old {
    for f in $(ls -- /etc/resolver/* 2>/dev/null) ; do
        [ -d "$f" ] && continue
        grep -iq '#added by Appgate' "$f" && rm -f "$f"
    done

    for key in $(echo "list State:.*/DNS" | scutil | grep State:/Network/Service/appgate-sdp-tunnel | awk '{print $NF}'); do
        echo "remove $key" | scutil
    done
}

function reset_dns {
    clear_old

    flush_dns_cache &

    # Trick to renew DHCP
    PRIMARY_INTERFACE=`printf "open\nget State:/Network/Global/IPv4\nd.show" | scutil | grep "PrimaryInterface" | awk '{print $3}'`
    echo "add State:/Network/Interface/$PRIMARY_INTERFACE/RefreshConfiguration temporary" | scutil

    return
}

RESOLV_CONF=/etc/resolv.conf
RUN_RESOLV_CONF=/var/run/resolv.conf
APPGATE_RESOLV_CONF=/var/run/resolv.conf.appgate
BACKUP_RESOLV_CONF=/etc/resolv.conf.appgate.backup

function reset_dns_legacy {
    if [[ $(readlink "$RESOLV_CONF") == "$APPGATE_RESOLV_CONF" ]]; then
        if [[ -f "$BACKUP_RESOLV_CONF" ]]; then
            rm -f "$RESOLV_CONF"
            mv "$BACKUP_RESOLV_CONF" "$RESOLV_CONF"
        else
            ln -s "$RUN_RESOLV_CONF" "$RESOLV_CONF"
        fi
    fi
    rm -f "$APPGATE_RESOLV_CONF" "$BACKUP_RESOLV_CONF"
}

function apply_dns_legacy {
    if [[ -f "$APPGATE_RESOLV_CONF" ]]; then
        rm -f "$BACKUP_RESOLV_CONF"
        mv "$RESOLV_CONF" "$BACKUP_RESOLV_CONF"
        ln -s "$APPGATE_RESOLV_CONF" "$RESOLV_CONF"
    fi
}

function dump_config_hash() {
    hash=$(cat /etc/resolver/* | shasum -a 256 | cut -d ' ' -f1)
    echo "CONFIG: $hash"
}

if [[ "$1" == "--hash" ]]; then
    dump_config_hash
    exit 0
fi

if [[ "$1" == "--reset" ]]; then
    [[ "$LEGACY" == "yes" ]] && reset_dns_legacy
    reset_dns
    exit 0
fi

declare -a servers
declare -a domains
declare -a searchdomains

if [[ "$1" == "--servers" ]]; then
    shift
    while [[ $# > 0 ]]; do
        [ "$1" == "--domains" ] && break
        servers+=($1)
        shift
    done
    [ ${#servers[@]} -eq 0 ] && usage
fi

[ "$1" == "--domains" ] || usage
shift
while [[ $# > 0 ]]; do
    
    if [[ "$1" == "dns.server."*"searchdomain."* ]]; then
        searchdomains+=($1)
    else
        domains+=($1)
    fi
    shift
done


ROOT=

#echo "Servers: ${servers[@]}"
#echo "Domains: ${domains[@]}"

function set_dns {
    clear_old

    mkdir -p $ROOT/etc/resolver

    # clean up after pre-4.2 client that created a file named '*'
    rm -f $ROOT/etc/resolver/\*

    for f in $(ls -- $ROOT/etc/resolver/* 2>/dev/null); do
        [ -d "$f" ] && continue
        grep -iq '#added by Appgate' "$f" && rm -f "$f"
    done

    rm -f $ROOT/var/run/.appgate-set-dns-*
    declare -a default
    for domain in "${domains[@]}"
    do
        if [[ "$domain" == "dns.server."* ]]; then
            IFS='.' read -r -a v <<< "$domain"
            if [[ "$domain" == *":"* ]]; then
                    ip="${v[2]}"
                    domain=`echo "${v[@]:3}" | tr '[ \t]' '.'`
                    searchdomain=""
            else
                    ip="${v[2]}.${v[3]}.${v[4]}.${v[5]}"
                    domain=`echo "${v[@]:6}" | tr '[ \t]' '.'`
                    searchdomain=""
            fi
        fi
        if [[ "$domain" != "default" ]]; then
        [ -f "$ROOT/var/run/.appgate-set-dns-$domain" ] || echo '#added by Appgate SDP' > "$ROOT/etc/resolver/$domain"
        echo "nameserver $ip" >> "$ROOT/etc/resolver/$domain"
        touch "$ROOT/var/run/.appgate-set-dns-$domain"
        for sd in "${searchdomains[@]}"; do
            IFS='.' read -r -a v <<< "$sd"
            if [[ "$sd" == *":"* ]]; then
                    ip="${v[2]}"
                    domain=`echo "${v[@]:4}" | tr '[ \t]' '.'`
                else
                    ip="${v[2]}.${v[3]}.${v[4]}.${v[5]}"
                    domain=`echo "${v[@]:7}" | tr '[ \t]' '.'`
                fi
            [ -f "$ROOT/var/run/.appgate-set-dns-$domain" ] || echo '#added by Appgate SDP' > "$ROOT/etc/resolver/$domain"
            grep -iq "$ip" "$ROOT/etc/resolver/$domain" || echo "nameserver $ip" >> "$ROOT/etc/resolver/$domain"
            echo "search $domain" >> "$ROOT/etc/resolver/$domain"
            touch "$ROOT/var/run/.appgate-set-dns-$domain"
        done
    else
        default+=($ip)
    fi
    if [[ ${#servers[@]} > 0 ]] && [[ ! -f "$ROOT/var/run/.appgate-set-dns-$domain" ]]; then
            rm -f "$ROOT/etc/resolver/$domain"
            echo '#added by Appgate SDP' > "$ROOT/etc/resolver/$domain"
            for server in "${servers[@]}"
            do
                echo "nameserver $server" >> "$ROOT/etc/resolver/$domain"
            done
            echo "search $domain" >> "$ROOT/etc/resolver/$domain"
        fi
    done

    for f in $(ls -- $ROOT/var/run/.appgate-set-dns-* 2>/dev/null); do
        rm -f "$f"
        domain=`echo $f | sed 's|.*/.appgate-set-dns-||'`
        [[ ${#servers[@]} > 0 ]] && echo "search $domain" >> "$ROOT/etc/resolver/$domain"
    done

    if [[ ${default[@]} ]]; then
        {
            echo "d.init"
            echo "d.add ServerAddresses * ${default[@]}"
            echo 'd.add SupplementalMatchDomains * ""'
            echo "d.add SupplementalMatchDomainsNoSearch 1"
            echo "set State:/Network/Service/appgate-sdp-tunnel-default/DNS"
        } | scutil
    fi

    flush_dns_cache &
    return
}

function gen_dns_legacy {
    declare -a search_domains
    for domain in "${domains[@]}"
    do
        if [[ "$domain" == "dns.server."* ]]; then
            IFS='.' read -r -a v <<< "$domain"
            if [[ "$domain" == *":"* ]]; then
                ip="${v[2]}"
                domain=`echo "${v[@]:3}" | tr '[ \t]' '.'`
            else
                ip="${v[2]}.${v[3]}.${v[4]}.${v[5]}"
                domain=`echo "${v[@]:6}" | tr '[ \t]' '.'`
            fi
            if [[ "$domain" == "default" ]]; then
                if [[ ! " ${servers[*]} " =~ " ${ip} " ]]; then
                    servers+=($ip)
                fi
            fi
        else
            search_domains+=($domain)
        fi
    done

    [ ${#servers[@]} -eq 0 ] && return

    echo "#Generated by Appgate" > "$APPGATE_RESOLV_CONF"
    echo "" >> $APPGATE_RESOLV_CONF
    for server in "${servers[@]}"
    do
        echo "nameserver $server" >> "$APPGATE_RESOLV_CONF"
    done

    if [[ ${#search_domains[@]} > 0 ]]; then
        echo "search ${search_domains[*]}" >> "$APPGATE_RESOLV_CONF"
    fi
}

set_dns

if [[ "$LEGACY" == "yes" ]]; then
    reset_dns_legacy
    gen_dns_legacy
    apply_dns_legacy
fi

dump_config_hash

exit 0
