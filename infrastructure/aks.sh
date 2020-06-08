#!/bin/bash
# This script is NOT idempotent. It is for illustration purposes only!

linebreak="***********************"

if [[ -z "${AZURE_HTTP_USER_AGENT}" ]]; then
  session=local
  echo "Please run this script from Azure Cloud Shell"
  exit 1
else
  session=azure
  echo "In Azure Cloud Shell"
fi

if [ "$session" == "azure" ]; then
  if [ ! -f "/home/$USER/.azure/azureProfile.json" ]; then
    echo "$linebreak"
    echo "We have to login to Azure to fetch the appropriate token, even through we're in Cloud Shell"
    login=$(az login)

    subs=$(az account show --query "{name:name,id:id}" --output tsv)
    echo "$linebreak"
    echo "Enter the number of the subscription you'd like to use"
    count=1
    while IFS=$'\n' read -r sub
    do
      format=" %-2d %60s\n"
      printf "$format $count) $sub" 
      let count=count+1 
    done <<< "$subs"

    echo ""
    read keystroke

    count=1
    while IFS=$'\t' read -r sub
    do
      if [ $keystroke == $count ]; then
        id=$(echo $sub | awk -F ' ' '{print $NF}')
        echo $id
        az account set -s $id
        break
      fi
      let count=count+1 
    done <<< "$subs"
  fi

  prefix=aks-coazure
  rg=${prefix}-${USER}
  location=$ACC_LOCATION
  vnet=aks-vnet
  subnet=aks-subnet
  sp='https://aks'
  aks=aks-coazure-cluster
  tags="[created=$(date +"%FT%T") type=testing]"
  
  echo "$linebreak"
  echo "Creating Resource Group $rg"
  rgjson=$(az group create --name $rg --location $location --tags $tags -o json)
  echo "Resource Group ID: $(echo $rgjson | jq -r ".id")"

  echo "$linebreak"
  echo "Creating VNet and Subnet for AKS and CNI"
  vnetjson=$(az network vnet create --resource-group $rg --location $location --name $vnet --address-prefixes 10.0.0.0/8 --subnet-name $subnet --subnet-prefix 10.240.0.0/16 -o json)
  vnetid=$(echo $vnetjson | jq -r ".newVNet.id")
  vnetname=$(echo $vnetjson | jq -r ".newVNet.name")
  echo "VNET ID: ${vnetid}"

  echo "$linebreak"
  echo "Creating a Service Principal to use for AKS VNET auth"
  spjson=$(az ad sp create-for-rbac --name $sp -o json)
  spid=$(echo $spjson | jq -r ".appId")
  spname=$(echo $spjson | jq -r ".displayName")
  
  echo "$linebreak"
  echo "Generate random password for AKS Service Principal (not production-ready!)"
  sppassword=
  count=0
  while [ $count -le 8 ]; do
    sppassword="$sppassword$RANDOM"
    let count=$count+1
  done
  credjson=$(az ad sp credential reset --name $sp --password $sppassword)
  echo "SPN: ${spid}"

  echo "$linebreak"
  echo "Assigning Service Principal ${spname}:${spid} the Contributor role to VNET ${vnetname}"
  rolejson=$(az role assignment create --assignee $spid --scope $vnetid --role Contributor -o json)
  
  echo "$linebreak"
  echo "Lookup Directory Read permissions in Graph API"
  graphapiguid="00000003-0000-0000-c000-000000000000" #known GUID
  readallapiid=$(az ad sp show --id $graphapiguid --query "appRoles[?contains(value, 'Directory.Read.All')].id" -o tsv)
  readalloauthid=$(az ad sp show --id $graphapiguid --query "oauth2Permissions[?contains(value, 'Directory.Read.All')].id" -o tsv)
  readuseroauthid=$(az ad sp show --id $graphapiguid --query "oauth2Permissions[?value == 'User.Read'].id" -o tsv)
 
  echo "$linebreak"
  echo "Generate random password for AKS Server AAD application (not production-ready!)"
  aksserverpassword=
  count=0
  while [ $count -le 8 ]; do
    aksserverpassword="$aksserverpassword$RANDOM"
    let count=$count+1
  done
  
  echo "$linebreak"
  echo "Creating AAD Application for AKS Server role"
  aksserverjson=$(az ad app create --display-name ${prefix}-server --identifier-uris api://aksservercredential-${RANDOM} --password $aksserverpassword -o json)
  serverid=$(echo $aksserverjson | jq -r '.appId')
  servername=$(echo $aksserverjson | jq -r '.displayName') 
  
  echo "$linebreak"
  echo "Grant "All" Group Membership Claims on AKS Server manifest"
  updateserverapp=$(az ad app update --id $serverid --set groupMembershipClaims="All")
  
  echo "$linebreak"
  echo "Disable existing OAuth2Permissions prior to updating" # https://anmock.blog/2020/01/10/azure-cli-create-an-azure-ad-application-for-an-api-that-exposes-oauth2-permissions/
  resetoauth=$(echo $aksserverjson | jq '.oauth2Permissions[0].isEnabled = false' | jq -r '.oauth2Permissions')
  updateserverappoauth=$(az ad app update --id $serverid --set oauth2Permissions="$resetoauth")
  
  serverresourcesmanifest=$(cat <<- EOF | jq -c '.'
  [{
      "resourceAppId": "$graphapiguid",
      "resourceAccess": [
        {
          "id": "${readalloauthid}",
          "type": "Scope"
        },
        {
          "id": "${readallapiid}",
          "type": "Role"
        },
        {
          "id": "${readuseroauthid}",
          "type": "Scope"
        }
      ]
    }]
EOF
  )
  
  serverresourceaccessid=$(cat /proc/sys/kernel/random/uuid)
  serveroauthmanifest=$(cat <<- EOF | jq -c '.'
  [{
      "adminConsentDescription": "AKSServerAPIEndpoint",
      "adminConsentDisplayName": "AKSServerAPIEndpoint",
      "id": "$serverresourceaccessid",
      "isEnabled": true,
      "lang": null,
      "origin": "Application",
      "type": "Admin",
      "userConsentDescription": null,
      "userConsentDisplayName": null,
      "value": "AKSServerAPIEndpoint"
    }]
EOF
  )
  
  echo "$linebreak"
  echo "Updating manifest for AKS Server app"
  updateaksserverjson=$(az ad app update --id $serverid --required-resource-accesses $serverresourcesmanifest --set oauth2Permissions="$serveroauthmanifest" -o json)
  
  echo "$linebreak"
  echo "Grant admin-consent to $servername ($serverid) AAD app (the account this script is running as must be an AAD admin in order for this to work!)"
  serverconsent=$(az ad app permission admin-consent --id $serverid -o json)
   
  echo "$linebreak"
  echo "Creating AAD Application for AKS Client role"
  aksclientjson=$(az ad app create --display-name ${prefix}-client --native-app --reply-urls https://afd.hosting.portal.azure.net/monitoring/Content/iframe/infrainsights.app/web/base-libs/auth/auth.html https://monitoring.hosting.portal.azure.net/monitoring/Content/iframe/infrainsights.app/web/base-libs/auth/auth.html -o json)
  clientid=$(echo $aksclientjson | jq -r '.appId')
  clientname=$(echo $aksclientjson | jq -r '.displayName')

  echo "$linebreak"
  echo "Grant AKS Client delegation permission to AKS Server"
  aksclientgrant=$(az ad app permission add --id $clientid --api $serverid --api-permissions $serverresourceaccessid=Scope)
  
  echo "$linebreak"
  echo "Grant admin-consent to $clientname ($clientid) AAD app (the account this script is running as must be an AAD admin in order for this to work!)"
  serverconsent=$(az ad app permission admin-consent --id $clientid -o json)

  echo "$linebreak"
  echo "Fetch Tenant ID"
  tenantid=$(az account show --query tenantId -o tsv)
  
  echo "$linebreak"
  echo "Starting AKS build"
  subnetid=$(az network vnet subnet show --resource-group $rg --vnet-name $vnet --name $subnet --query id -o tsv)
  k8sversion=$(az aks get-versions --location $location --query 'orchestrators[?!isPreview] | [-1].orchestratorVersion' -o tsv)
  az aks create \
  --resource-group $rg \
  --name $aks \
  --vm-set-type VirtualMachineScaleSets \
  --load-balancer-sku standard \
  --location $location \
  --kubernetes-version $k8sversion \
  --network-plugin azure \
  --vnet-subnet-id $subnetid \
  --service-cidr 10.2.0.0/24 \
  --dns-service-ip 10.2.0.10 \
  --docker-bridge-address 172.17.0.1/16 \
  --generate-ssh-keys \
  --enable-managed-identity \
  --service-principal $spid \
  --client-secret $sppassword \
  --aad-client-app-id $clientid \
  --aad-server-app-id  $serverid \
  --aad-server-app-secret $aksserverpassword \
  --aad-tenant-id $tenantid
fi
