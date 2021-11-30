#!/bin/sh

TALISMAN_IMAGE=portworx/talisman
TALISMAN_TAG=1.1.0
WIPE_CLUSTER="--wipecluster"
MAX_RETRIES=60
TIME_BEFORE_RETRY=5 #seconds
JOB_NAME=talisman
KUBECTL_EXTRA_OPTS=""
WIPER_IMAGE=portworx/px-node-wiper
WIPER_TAG=2.5.0

usage() {
  cat <<EOF
	usage:  curl https://install.portworx.com/px-wipe | bash -s [-- [-wi <wiper-image>] [-wt <wiper-tag>] [-S | --skipmetadata] ]
	examples:
            # Along with deleting Portworx Kubernetes components, also wipe Portworx cluster metadata
            curl https://install.portworx.com/px-wipe | bash -s -- --skipmetadata
EOF
}

fatal() {
  echo "" 2>&1
  echo "$@" 2>&1
  exit 1
}

# derived from https://gist.github.com/davejamesmiller/1965569
ask() {
  local prompt default reply
  if [ "${2:-}" = "Y" ]; then
    prompt="Y/n"
    default=Y
  elif [ "${2:-}" = "N" ]; then
    prompt="y/N"
    default=N
  else
    prompt="y/n"
    default=
  fi

  # Ask the question (not using "read -p" as it uses stderr not stdout)<Paste>
  echo -n "$1 [$prompt]:"

  # Read the answer (use /dev/tty in case stdin is redirected from somewhere else)
  read reply </dev/tty || \
    fatal "ERROR: Could not ask for user input - please run via interactive shell"

  # Default? (e.g user presses enter)
  if [ -z "$reply" ]; then
    reply=$default
  fi

  # Check if the reply is valid
  case "$reply" in
    Y*|y*) return 0 ;;
    N*|n*) return 1 ;;
    * )    echo "invalid reply: $reply"; return 1 ;;
  esac
}

FORCE_DELETE="false"
while [ "$1" != "" ]; do
    case $1 in
        -I | --talismanimage ) shift
                                TALISMAN_IMAGE=$1
                                ;;
        -T | --talismantag )   shift
                                TALISMAN_TAG=$1
                                ;;
        -wi | --wiperimage ) shift
                                WIPER_IMAGE=$1
                                ;;
        -wt | --wipertag )   shift
                                WIPER_TAG=$1
                                ;;
        -S | --skipmetadata )   WIPE_CLUSTER=""
                                ;;
        -f | --force )          FORCE_DELETE="true"
                                ;;
        -h | --help )           usage
                                ;;
        * )                     usage
    esac
    shift
done
if [ "x$FORCE_DELETE" = xtrue ]; then
  echo "[WARN]: Detected a force delete request! Force deleting..."
elif [ "x$WIPE_CLUSTER" = x ]; then
  ask "The operation will delete Portworx components from the cluster. Do you want to continue?" N || \
    fatal "Aborting Portworx wipe from the cluster..."
else
  ask "The operation will delete Portworx components and metadata from the cluster. The operation is irreversible and will lead to DATA LOSS. Do you want to continue?" N || \
    fatal "Aborting Portworx wipe from the cluster..."
fi

_out=$(oc whoami 2>&1)
if [ $? -eq 0 ]; then
  echo "Detected OpenShift system. Adding talisman-account user to privileged scc"
  oc adm policy add-scc-to-user privileged system:serviceaccount:kube-system:talisman-account || \
    fatal "failed to add talisman-account to privileged scc. exit code: $?"
fi

# Check versions, set default params accordingly
VER=$(kubectl version --short 2>&1)
SERVER_VER=$(echo "$VER" | awk -Fv '/Server Version: /{print $3}')
CLIENT_VER=$(echo "$VER" | awk -Fv '/Client Version: /{print $2}')

case $SERVER_VER in
  '')
    fatal "failed to get kubernetes server version. Make sure you have kubectl setup on current machine."
    ;;
  1.7*|1.6*)
    fatal "This script doesn't support wiping Portworx from Kubernetes v$SERVER_VER clusters. Refer to https://docs.portworx.com/scheduler/kubernetes/install.html for instructions"
    ;;
esac

[ "x$CLIENT_VER" != x ] || \
  fatal "failed to get kubernetes client version. Make sure you have kubectl setup on current machine."

KUBECTL_EXTRA_OPTS=""
CLIENT_VERI=$(echo $CLIENT_VER | awk -F. '{print $1*100+$2}')
if [ $CLIENT_VERI -lt 114 ]; then
  KUBECTL_EXTRA_OPTS="--show-all"
fi

echo "Parsed kubernetes versions are $SERVER_VER (Server) and $CLIENT_VER (Client)"

# Delete old talisman job/pods
_out=$(kubectl delete -n kube-system job talisman 2>/dev/null)
RETRY_CNT=0
while true; do
  PODS=$(kubectl get pods -n kube-system -l name=$JOB_NAME $KUBECTL_EXTRA_OPTS 2>/dev/null)
  if [ $? -eq 0 ]; then
    NUM_PODS=$(echo -n "$PODS" | grep -c -v NAME)
    [ $NUM_PODS -eq 0 ] && break
  fi

  RETRY_CNT=$((RETRY_CNT+1))
  [ $RETRY_CNT -lt $MAX_RETRIES ] || \
    fatal "failed to delete old talisman pods  (Timeout!)"
  sleep $TIME_BEFORE_RETRY
done

# Set up cleanup trap  (on exit, SIGINT, SIGQUIT, SIGTERM)
cleanup() {
  rc=$? ; rc2=0
  echo "Cleaning up resources..."
  kubectl delete job -n kube-system talisman                    || rc2=$?
  kubectl delete serviceaccount -n kube-system talisman-account || rc2=$?
  kubectl delete clusterrolebinding talisman-role-binding       || rc2=$?
  kubectl delete crd volumeplacementstrategies.portworx.io
  [ $rc2 -eq 0 ] || \
    fatal "error cleaning up job/pods"
  exit $rc
}
trap cleanup EXIT 2 3 15


cat <<EOF | kubectl apply -f -
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: talisman-account
  namespace: kube-system
---
kind: ClusterRoleBinding
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: talisman-role-binding
subjects:
- kind: ServiceAccount
  name: talisman-account
  namespace: kube-system
roleRef:
  kind: ClusterRole
  name: cluster-admin
  apiGroup: rbac.authorization.k8s.io
---

apiVersion: batch/v1
kind: Job
metadata:
  name: $JOB_NAME
  namespace: kube-system
spec:
  backoffLimit: 1
  template:
    metadata:
      labels:
        name: $JOB_NAME
    spec:
      serviceAccount: talisman-account
      containers:
      - name: $JOB_NAME
        image: $TALISMAN_IMAGE:$TALISMAN_TAG
        args: ["-operation", "delete", "$WIPE_CLUSTER", "-wiperimage", "$WIPER_IMAGE", "-wipertag", "$WIPER_TAG"]
        imagePullPolicy: Always
        volumeMounts:
        - name: etcpwx
          mountPath: /etc/pwx
      volumes:
      - name: etcpwx
        hostPath:
          path: /etc/pwx
      restartPolicy: Never
EOF

echo "Talisman job for wiping Portworx started. Monitor logs using: 'kubectl logs -n kube-system -l job-name=talisman'"

NUM_DESIRED=1
RETRY_CNT=0
while true; do
  NUM_SUCCEEDED=0
  NUM_FAILED=0
  PODS=$(kubectl get pods -n kube-system -l name=$JOB_NAME 2>/dev/null)
  if [ $? -eq 0 ]; then
    CREATING=$(echo "$PODS" | grep ContainerCreating)
    if [ ! -z "$CREATING" ]; then
      echo "Pod that will perform wipe of Portworx is still in container creating phase"
    else
      NUM_FAILED=$(kubectl get job -n kube-system talisman $KUBECTL_EXTRA_OPTS -o jsonpath='{.status.failed}' 2>/dev/null)
      if [ $? -eq 0 ]; then
        if [ ! -z "$NUM_FAILED" ] && [ $NUM_FAILED -ge 1 ]; then
          kubectl logs -n kube-system -l name=$JOB_NAME
          fatal "Job to wipe px cluster failed."
        fi
      fi

      NUM_SUCCEEDED=$(kubectl get job -n kube-system talisman $KUBECTL_EXTRA_OPTS -o jsonpath='{.status.succeeded}' 2>/dev/null)
      if [ ! -z "$NUM_SUCCEEDED" ] && [ $NUM_SUCCEEDED -eq $NUM_DESIRED ]; then
        break
      fi

      echo "waiting on $JOB_NAME to complete..."
      RUNNING_POD=$(echo "$PODS" | grep Running | awk '/^talisman/{print $1}')
      if [ ! -z "$RUNNING_POD" ]; then
        echo "Monitoring logs of pod: $RUNNING_POD"
        kubectl logs -n kube-system -f $RUNNING_POD
      fi
    fi
  fi

  RETRY_CNT=$((RETRY_CNT+1))
  if [ $RETRY_CNT -ge $MAX_RETRIES ]; then
    kubectl logs -n kube-system -l name=$JOB_NAME
    fatal "Timed out trying to wipe Portworx cluster."
  fi

  sleep $TIME_BEFORE_RETRY
done

echo "Portworx cluster wipe succesfully completed."
