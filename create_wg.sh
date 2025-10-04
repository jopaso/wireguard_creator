#!/bin/bash

function ctrl_c(){
  echo -e "\n\nEXITING\n"
  tput cnorm && exit 1
}
## Ctrl+C
trap ctrl_c INT

function helpPanel(){
    echo -e "How to use: ${0} -<argument>"
    echo -e "\t-s: Create the configuration files and set up the vpn"
    echo -e "\t-c <name>: Create the configuration for a new user"
    
    exit 1
}

#Gets public ip
get_public_ip() {
    local ip
    for service in \
        "https://api.ipify.org" \
        "https://ifconfig.me" \
        "https://icanhazip.com" \
        "https://checkip.amazonaws.com"
    do
        ip=$(curl -s --max-time 5 "$service")
        if [[ $ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo "$ip"
            return 0
        fi
    done
    return 1
}

#Cheks if the user is root (otherwise you can't write at /etc)
function check_user(){
    user=$(whoami)
    if [ "$user" != "root" ]; then
        echo -e "[+] You need to run this file as root.\n\n EXITING..."
        tput cnorm && exit 1
    fi
}

function install_wg(){
    which wg > /dev/null
    code=$?

    if [ "$code" -eq 1 ]; then
       sudo apt-get install wireguard-tools 
    fi
}

## Server_Creation

function create_server_key(){
    mkdir ${path}/server_keys
    wg genkey | tee ${path}/server_keys/server_privatekey | wg pubkey > ${path}/server_keys/server_publickey
    echo "[+] Server Keys created in directory ${path}/server_keys"
}

function create_wg_config_file() {
    echo "Introduce the interface you want to use"
    read interface
    echo -e "[Interface]
Address = 10.0.0.1/32
SaveConfig = true
PostUp = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o ${interface}  -j MASQUERADE;
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o ${interface} -j MASQUERADE;
ListenPort = 51820
PrivateKey = $(cat ${path}/server_keys/server_privatekey)" > ${path}/wg0.conf

    echo "[+] Wireguard configuration file created as ${path}/wg0.conf" 
}

function create_server(){
    install_wg
    mkdir /etc/wireguard/ > /dev/null
    create_server_key
    create_wg_config_file
    # wg up
    wg-quick up wg0
    sysctl -w net.ipv4.ip_forward=1
    
}

## CLIENTS


function create_client_keys(){
    name=$1
    mkdir ${path}/client_keys/ 2>/dev/null
    mkdir ${path}/client_keys/${name}_keys 2>/dev/null
    
    if [ "$?" -gt 0 ]; then
        echo "[+] Name already in use. Please select another name" && exit 1
    fi

    wg genkey | tee ${path}/client_keys/${name}_keys/${name}_privatekey | wg pubkey > ${path}/client_keys/${name}_keys/${name}_publickey
    echo "[+] Keys created in ${path}/client_keys/${name}_keys"
}

function create_client_file(){
    name=$1
    addr=$2
    ip=$(get_public_ip)
    echo -e "[Interface]
PrivateKey = $(cat ${path}/client_keys/${name}_keys/${name}_privatekey)
Address = 10.0.0.${addr}/32
DNS = 8.8.8.8

[Peer]
PublicKey = $(cat ${path}/server_keys/server_publickey)
Endpoint = ${ip}:51820
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 30\n" > ${path}/client_keys/${name}_keys/wg_${name}.conf

    echo -e "[+] You can access scanning this QR: \n"
    qrencode -t ansiutf8 < ${path}/client_keys/${name}_keys/wg_${name}.conf 2>/dev/null
}

function add_client_conf() {
    name=$1
    addr=$2
    wg-quick down wg0

    echo -e "\n[Peer] #${name}
PublicKey = $(cat ${path}/client_keys/${name}_keys/${name}_publickey)
AllowedIPs = 10.0.0.${addr}/32\n" >> ${path}/wg0.conf

    wg set wg0 peer $(cat ${path}/client_keys/${name}_keys/${name}_publickey) allowed-ips 10.0.0.${addr}/32
    echo "[+] Added peer"
    wg-quick up wg0
}

function create_client(){
    name=$1
    create_client_keys $name
    addr=$(($(ls ${path}/client_keys/ | wc -l) + 1))
    add_client_conf $name $addr
    create_client_file $name $addr
    echo "[+] Client wg conf file created  directory ${path}/client_keys/${name}_keys"

}

function remove_client() {
    name=$1
    sed -i "/#${name}$/,+5d" "${path}/wg0.conf"
    rm -r ${path}/$client_keys/${name}_keys 2>/dev/null
    systemctl restart wg-quick@wg0
    echo -e "[+] Client ${name} removed"
}

check_user
path="/etc/wireguard"
if [ "$1" = "-c" ] && [ -n "${2}" ]; then
    echo "[+] Creating client ${2}..."
    create_client $2

elif [ "$1" = "-s" ]; then
    echo "[+] Creating server..."
    create_server

elif [ "${1}" = "-r" ] && [ -n "${2}" ]; then
    remove_client $2

else 
    echo "[+] Argumento incorrecto"
    helpPanel
fi