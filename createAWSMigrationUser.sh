#!/bin/bash

aws iam create-user --user-name migration --output json

aws iam create-access-key --user-name migration --output json

aws iam put-user-policy --user-name migration --policy-name migration-policy --policy-document file://migration-policy.json
