#!/usr/bin/env python3

import atexit
import subprocess
import json
import requests
import sys
import socket
import time

PROXY_PORT = 8001

def start_proxy():
  proxy_process = subprocess.Popen(['kubectl', 'proxy', '-p', str(PROXY_PORT)])
  atexit.register(proxy_process.kill)
  # wait proxy become available
  time.sleep(1)


def is_port_free(port, host='127.0.0.1'):
  s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
  result = s.connect_ex((host, port))
  s.close()
  return False if result == 0 else True


def ns_exists(ns):
  try:
    r = requests.get('http://127.0.0.1:{}/api/v1/namespaces'.format(PROXY_PORT))
    data = r.json()
    current_ns = [ns.get('metadata', {}).get('name') for ns in data.get('items', {})]
    return True if ns in current_ns else False
  except Exception as e:
    print(e)
    sys.exit(1)


def get_ns(ns):
  try:
    if not ns_exists(ns):
      print('Namespace {} does not exist'.format(ns))
      sys.exit(1)

    r = requests.get('http://127.0.0.1:{}/api/v1/namespaces/{}'.format(PROXY_PORT, ns))
    data = r.json()
    return data
  except Exception as e:
    print(e)
    sys.exit(1)


if len(sys.argv) < 2:
  print('{} <namespace> [API URL]'.format(sys.argv[0]))
  sys.exit(1)
else:
  namespace = sys.argv[1]

while not is_port_free(port=PROXY_PORT):
  PROXY_PORT += 1

start_proxy()

payload = get_ns(namespace)
payload['spec']['finalizers'] = []

#p = subprocess.Popen(['kubectl', 'get', 'namespace', namespace, '-o', 'json'], stdout=subprocess.PIPE)
#p.wait()
#data = json.load(p.stdout)
#data['spec']['finalizers'] = []

try:
  requests.put('http://127.0.0.1:8001/api/v1/namespaces/{}/finalize'.format(namespace), json=payload).raise_for_status()
except Exception as e:
  sys.exit(1)
