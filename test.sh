
# Source the environment variables.
source vault.env
vault status
export VAULT_TOKEN=$(gsutil cat gs://${GCS_BUCKET_NAME}/root-token.enc | \
  base64 --decode | \
  gcloud kms decrypt \
    --project ${PROJECT_ID} \
    --location global \
    --keyring vault \
    --key vault-init \
    --ciphertext-file - \
    --plaintext-file - 
)
vault secrets enable -version=2 kv
vault kv enable-versioning secret/
vault kv put secret/my-secret my-value=s3cr3t
vault kv get secret/my-secret
