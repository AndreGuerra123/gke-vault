#! /bin/bash

export PROJECT_ID=$(gcloud config get-value project)
export GCS_BUCKET_NAME="${PROJECT_ID}-storage"
export KMS_KEY_ID="projects/${PROJECT_ID}/locations/global/keyRings/vault/cryptoKeys/vault-init"
export COMPUTE_REGION="europe-west3"
export COMPUTE_ZONE="europe-west3-a"

# Activate necessary API's
gcloud services enable cloudapis.googleapis.com cloudkms.googleapis.com container.googleapis.com containerregistry.googleapis.com iam.googleapis.com --project ${PROJECT_ID}

# Create Keyring and Key
gcloud kms keyrings create vault --location global --project ${PROJECT_ID}
gcloud kms keys create vault-init --location global --keyring vault --purpose encryption -project ${PROJECT_ID}

# Create the Storage Bucket
gsutil mb -p ${PROJECT_ID} gs://${GCS_BUCKET_NAME}

# Create the IAM Service Account
gcloud iam service-accounts create vault-server --display-name "Vault Service Account" --project ${PROJECT_ID}

gsutil iam ch serviceAccount:vault-server@${PROJECT_ID}.iam.gserviceaccount.com:objectAdmin gs://${GCS_BUCKET_NAME}
gsutil iam ch serviceAccount:vault-server@${PROJECT_ID}.iam.gserviceaccount.com:legacyBucketReader gs://${GCS_BUCKET_NAME}
gcloud kms keys add-iam-policy-binding vault-init --location global --keyring vault --member serviceAccount:vault-server@${PROJECT_ID}.iam.gserviceaccount.com --role roles/cloudkms.cryptoKeyEncrypterDecrypter --project ${PROJECT_ID}

# Starting Kubernetes cluster
gcloud container clusters create vault --enable-autorepair --cluster-version 1.11.2-gke.9 --machine-type n1-standard-2 --service-account vault-server@${PROJECT_ID}.iam.gserviceaccount.com --num-nodes 3 --zone ${COMPUTE_ZONE} --project ${PROJECT_ID}

# Provisioning the IP Address
gcloud compute addresses create vault --region ${COMPUTE_REGION} --project ${PROJECT_ID}
export VAULT_LOAD_BALANCER_IP=$(gcloud compute addresses describe vault --region ${COMPUTE_REGION} --project ${PROJECT_ID} --format='value(address)')

#Generate the TLS Certificates
cfssl gencert -initca ca-csr.json | cfssljson -bare ca
cfssl gencert -ca=ca.pem -ca-key=ca-key.pem -config=ca-config.json -hostname="vault,vault.default.svc.cluster.local,localhost,127.0.0.1,${VAULT_LOAD_BALANCER_IP}" -profile=default vault-csr.json | cfssljson -bare vault

#Deploy Vault
cat vault.pem ca.pem > vault-combined.pem
kubectl create secret generic vault --from-file=ca.pem --from-file=vault.pem=vault-combined.pem --from-file=vault-key.pem
kubectl create configmap vault --from-literal api-addr=https://${VAULT_LOAD_BALANCER_IP}:8200 --from-literal gcs-bucket-name=${GCS_BUCKET_NAME} --from-literal kms-key-id=${KMS_KEY_ID}
kubectl apply -f vault.yaml

#Automatic initialization
kubectl logs vault-0 -c vault-init

#Expose
cat > vault-load-balancer.yaml <<EOF
apiVersion: v1
kind: Service
metadata:
  name: vault-load-balancer
spec:
  type: LoadBalancer
  loadBalancerIP: ${VAULT_LOAD_BALANCER_IP}
  ports:
    - name: http
      port: 8200
    - name: server
      port: 8201
  selector:
    app: vault
EOF

kubectl apply -f vault-load-balancer.yaml
export VAULT_TOKEN=$(gsutil cat gs://${GCS_BUCKET_NAME}/root-token.enc | base64 --decode | gcloud kms decrypt --project ${PROJECT_ID} --location global --keyring vault --key vault-init --ciphertext-file - --plaintext-file - )
