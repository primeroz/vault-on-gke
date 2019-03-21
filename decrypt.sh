#!/bin/bash

gsutil cat gs://vault9eacd36a1c0fec82-vault-storage/vault-root | gcloud kms decrypt --project vault9eacd36a1c0fec82 --location europe-west4 --keyring vault --key vault-init --ciphertext-file - --plaintext-file -
