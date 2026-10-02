#!/bin/bash
# Bring up RKE2 on retail-rancher01..03 (addresses from hosts.txt) with an
# in-cluster VIP instead of external load balancers, then install cert-manager
# and Rancher (community rancher-stable chart) through the RKE2 helm-controller.
#
# VIP (SUSE Edge pattern): MetalLB in L2 mode announces ${VIP} from one node.
#   - kubernetes-vip (default ns, LoadBalancer, ports 6443 + 9345) has no
#     selector; Endpoint Copier Operator keeps its endpoints equal to the
#     "kubernetes" service's, i.e. every control-plane node's apiserver.
#   - The RKE2 ingress controller's LoadBalancer service shares the same IP
#     (allow-shared-ip) for 80/443, so Rancher's UI and the registration
#     endpoint stores use are on the VIP too.
# Order: node 01 alone -> MetalLB + ECO + VIP services -> nodes 02/03 join
# through the VIP on 9345 -> Rancher.
#
# Rancher serves a certificate from the HQ CA in pki/ (make-pki.sh).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
RANCHER_VERSION=2.15.2
CERT_MANAGER_VERSION=v1.21.2
METALLB_CHART_VERSION=307.0.3+up0.16.1
ECO_CHART_VERSION=307.0.1+up0.3.0
VIP_SHARE_KEY=retail-hq-vip
NODES=($(for n in $(nodes_of_role rancher); do ip_of "$n"; done))
SSH_IN="ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new"
KUBECTL="/var/lib/rancher/rke2/bin/kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml"

[ ${#NODES[@]} -eq 3 ] || { echo "ERROR: hosts.txt incomplete - run ./discover-ips.sh" >&2; exit 1; }
[ -f "${DIR}/pki/rancher.key" ] || { echo "ERROR: no pki/ - run ./make-pki.sh" >&2; exit 1; }

# Secrets are generated once and kept next to this script
CREDS="${DIR}/credentials.env"
if [ ! -f "$CREDS" ]; then
  umask 077
  cat >"$CREDS" <<EOF
RKE2_TOKEN=$(openssl rand -hex 24)
RANCHER_BOOTSTRAP_PASSWORD=$(openssl rand -base64 18 | tr -d '/+=')
EOF
fi
source "$CREDS"

k() { $SSH root@"${NODES[0]}" "$KUBECTL $*"; }
manifest() { # name - writes stdin to node 01's RKE2 auto-deploy directory
  $SSH_IN root@"${NODES[0]}" "umask 077; cat > /var/lib/rancher/rke2/server/manifests/$1.yaml"
}

rke2_config() { # index
  cat <<EOF
token: ${RKE2_TOKEN}
write-kubeconfig-mode: "0644"
selinux: true
tls-san:
  - ${VIP}
  - ${RANCHER_FQDN}
EOF
  [ "$1" -eq 0 ] || echo "server: https://${VIP}:9345"
}

node_ready() { k get nodes -o wide | grep -F " $1 " | grep -qw Ready; }

start_node() { # index
  local ip=${NODES[$1]}
  echo "==> retail-rancher0$(($1 + 1)) (${ip})"
  $SSH_IN root@"$ip" "mkdir -p /etc/rancher/rke2 && cat > /etc/rancher/rke2/config.yaml" <<<"$(rke2_config "$1")"
  $SSH root@"$ip" "systemctl enable --now rke2-server"
  wait_for "retail-rancher0$(($1 + 1)) Ready" 900 node_ready "$ip"
}

# --- 1. First node ---------------------------------------------------------
start_node 0

# --- 2. VIP: MetalLB + Endpoint Copier Operator ----------------------------
echo "==> MetalLB ${METALLB_CHART_VERSION} and Endpoint Copier Operator ${ECO_CHART_VERSION}"
manifest vip-operators <<EOF
apiVersion: helm.cattle.io/v1
kind: HelmChart
metadata:
  name: metallb
  namespace: kube-system
spec:
  chart: oci://registry.suse.com/edge/charts/metallb
  version: "${METALLB_CHART_VERSION}"
  targetNamespace: metallb-system
  createNamespace: true
---
apiVersion: helm.cattle.io/v1
kind: HelmChart
metadata:
  name: endpoint-copier-operator
  namespace: kube-system
spec:
  chart: oci://registry.suse.com/edge/charts/endpoint-copier-operator
  version: "${ECO_CHART_VERSION}"
  targetNamespace: endpoint-copier-operator
  createNamespace: true
EOF
wait_for "MetalLB controller ready" 600 \
  k -n metallb-system wait --for=condition=Available deploy -l app.kubernetes.io/component=controller --timeout=5s

# The pool only hands out the VIP to services that ask for it by annotation.
# The webhook may need a moment after the controller reports Available.
VIP_CONFIG=$(
  cat <<EOF
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: hq-vip
  namespace: metallb-system
spec:
  addresses:
    - ${VIP}/32
  autoAssign: false
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: hq-vip
  namespace: metallb-system
spec:
  ipAddressPools:
    - hq-vip
  interfaces:
    - enp1s0
---
apiVersion: v1
kind: Service
metadata:
  name: kubernetes-vip
  namespace: default
  annotations:
    metallb.io/loadBalancerIPs: ${VIP}
    metallb.io/allow-shared-ip: ${VIP_SHARE_KEY}
spec:
  type: LoadBalancer
  externalTrafficPolicy: Cluster
  ports:
    - name: rke2-supervisor
      port: 9345
      protocol: TCP
      targetPort: 9345
    - name: k8s-api
      port: 6443
      protocol: TCP
      targetPort: 6443
EOF
)
apply_vip() { $SSH_IN root@"${NODES[0]}" "$KUBECTL apply -f -" <<<"$VIP_CONFIG"; }
wait_for "VIP pool and kubernetes-vip service applied" 300 apply_vip
wait_for "VIP ${VIP}:9345 answering" 300 curl -sk --max-time 3 -o /dev/null "https://${VIP}:9345/ping"

# --- 3. Remaining nodes join through the VIP --------------------------------
start_node 1
start_node 2

# --- 4. Ingress on the VIP, then cert-manager + Rancher ---------------------
# RKE2 picks the ingress controller (traefik or ingress-nginx depending on
# release); give whichever is deployed a LoadBalancer service on the shared VIP.
if k -n kube-system get helmchart rke2-traefik >/dev/null 2>&1; then
  INGRESS=rke2-traefik
  INGRESS_VALUES="service:
  enabled: true
  type: LoadBalancer
  spec:
    externalTrafficPolicy: Cluster
  annotations:
    metallb.io/loadBalancerIPs: ${VIP}
    metallb.io/allow-shared-ip: ${VIP_SHARE_KEY}"
elif k -n kube-system get helmchart rke2-ingress-nginx >/dev/null 2>&1; then
  INGRESS=rke2-ingress-nginx
  INGRESS_VALUES="controller:
  publishService:
    enabled: true
  service:
    enabled: true
    type: LoadBalancer
    externalTrafficPolicy: Cluster
    annotations:
      metallb.io/loadBalancerIPs: ${VIP}
      metallb.io/allow-shared-ip: ${VIP_SHARE_KEY}"
else
  echo "ERROR: no rke2-traefik or rke2-ingress-nginx HelmChart found" >&2
  exit 1
fi
echo "==> ${INGRESS} gets a LoadBalancer service on ${VIP}"
manifest ingress-vip <<EOF
apiVersion: helm.cattle.io/v1
kind: HelmChartConfig
metadata:
  name: ${INGRESS}
  namespace: kube-system
spec:
  valuesContent: |-
$(sed 's/^/    /' <<<"$INGRESS_VALUES")
EOF

b64() { base64 -w0 "$1"; }
echo "==> cert-manager ${CERT_MANAGER_VERSION} and Rancher ${RANCHER_VERSION} (rancher-stable)"
manifest rancher <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: cattle-system
---
apiVersion: v1
kind: Secret
metadata:
  name: tls-rancher-ingress
  namespace: cattle-system
type: kubernetes.io/tls
data:
  tls.crt: $(b64 "${DIR}/pki/rancher.pem")
  tls.key: $(b64 "${DIR}/pki/rancher.key")
---
apiVersion: v1
kind: Secret
metadata:
  name: tls-ca
  namespace: cattle-system
data:
  cacerts.pem: $(b64 "${DIR}/pki/ca.pem")
---
apiVersion: helm.cattle.io/v1
kind: HelmChart
metadata:
  name: cert-manager
  namespace: kube-system
spec:
  repo: https://charts.jetstack.io
  chart: cert-manager
  version: ${CERT_MANAGER_VERSION}
  targetNamespace: cert-manager
  createNamespace: true
  valuesContent: |-
    crds:
      enabled: true
---
apiVersion: helm.cattle.io/v1
kind: HelmChart
metadata:
  name: rancher
  namespace: kube-system
spec:
  # rancher-stable: the community chart repo
  repo: https://releases.rancher.com/server-charts/stable
  chart: rancher
  version: ${RANCHER_VERSION}
  targetNamespace: cattle-system
  createNamespace: true
  valuesContent: |-
    hostname: ${RANCHER_FQDN}
    replicas: 3
    bootstrapPassword: ${RANCHER_BOOTSTRAP_PASSWORD}
    privateCA: true
    ingress:
      tls:
        source: secret
EOF

wait_for "Rancher /ping through the VIP" 1200 \
  sh -c "curl -sf --cacert '${DIR}/pki/ca.pem' --max-time 5 --resolve ${RANCHER_FQDN}:443:${VIP} ${RANCHER_URL}/ping | grep -qx pong"

rancher_login
api PUT /v3/settings/server-url "{\"value\":\"${RANCHER_URL}\"}" >/dev/null
api PUT /v3/settings/first-login '{"value":"false"}' >/dev/null
echo "==> Rancher is up at ${RANCHER_URL} (admin / RANCHER_BOOTSTRAP_PASSWORD in credentials.env)"
