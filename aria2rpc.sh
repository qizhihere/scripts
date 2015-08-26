#!/bin/bash
usage='Usage: aria2rpc.sh [-c COOKIE] [-d DIR] [-o NAME] URL [URL..]'

while [[ -n "$1" ]];do
  case "$1" in
    -c|--cookie) shift; cookie="$1" ;;
    -d|--dir) shift; dir="$1" ;;
    -o|--out) shift; output="$1" ;;
    -r|--rpc) shift; rpc="$1" ;;
    -h|--help) echo "$usage"; exit ;;
    *) uris[$((i++))]="$1" ;;
  esac
  shift
done

if ((${#uris[@]}==0));then
  echo "$usage"
  exit
fi
URIs=$(IFS=, ;echo "${uris[*]}"|sed 's/,/","/g;s/^/"/;s/$/"/')

if [[ -z "$rpc" ]];then
  rpc='http://127.0.0.1:6800/jsonrpc'
fi

Options="{"
if [[ -n "$cookie" ]];then
  Options="$Options"'"header":["Cookie: '"$cookie"'"],'
fi
if [[ -n "$dir" ]];then
  Options="$Options"'"dir":"'"$dir"'",'
fi
if [[ -n "$output" ]];then
  Options="$Options"'"out":"'"$output"'",'
fi
Options="${Options%,}"
Options="$Options""}"

jsonTemplate='{"jsonrpc":"2.0","id":"qwer","method":"aria2.addUri","params":[['"$URIs"'],'"$Options"']}'

curl -X POST -d "$jsonTemplate" --header "Content-Type:application/json" "$rpc"
