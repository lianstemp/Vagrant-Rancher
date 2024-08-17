#!/bin/bash

# Rancher API details
RANCHER_URL="https://192.168.56.101/v3"
RANCHER_TOKEN="token-b854d:vkw9pgt9chvsgmnh8xqh2tzfshqgq4tqcqmmkmmfm5zx4m7mlwcvbs"
NAMESPACE="mysql-service"

# Function to make API calls
make_api_call() {
    local method=$1
    local endpoint=$2
    local data=$3
    local max_retries=5
    local retry_count=0
    local response

    while [ $retry_count -lt $max_retries ]; do
        response=$(curl -k -s -X "$method" -H "Authorization: Bearer $RANCHER_TOKEN" -H "Content-Type: application/json" \
            ${data:+-d "$data"} \
            "${RANCHER_URL}${endpoint}")

        if [[ $(echo "$response" | jq -r '.type' 2>/dev/null) == "error" ]]; then
            echo "Error: $(echo "$response" | jq -r '.message')" >&2
            retry_count=$((retry_count + 1))
            sleep 5
        else
            echo "$response"
            return 0
        fi
    done

    echo "Failed after $max_retries attempts" >&2
    return 1
}

# Get Cluster, Project, and Namespace IDs
get_cluster_project_namespace_ids() {
    CLUSTER_ID=$(make_api_call GET "/clusters" | jq -r '.data[0].id')
    PROJECT_ID=$(make_api_call GET "/projects?clusterId=$CLUSTER_ID" | jq -r '.data[0].id')

    NAMESPACE_ID=$(make_api_call GET "/clusters/${CLUSTER_ID}/namespaces?name=${NAMESPACE}" | jq -r '.data[0].id')
    if [ -z "$NAMESPACE_ID" ] || [ "$NAMESPACE_ID" == "null" ]; then
        echo "Creating namespace: $NAMESPACE"
        response=$(make_api_call POST "/clusters/${CLUSTER_ID}/namespaces" \
            "{\"type\":\"namespace\",\"name\":\"$NAMESPACE\",\"clusterId\":\"$CLUSTER_ID\",\"projectId\":\"$PROJECT_ID\"}")
        NAMESPACE_ID=$(echo "$response" | jq -r '.id')
        if [ -z "$NAMESPACE_ID" ] || [ "$NAMESPACE_ID" == "null" ]; then
            echo "Failed to create namespace. Response: $response" >&2
            exit 1
        fi
    fi

    echo "Cluster ID: $CLUSTER_ID"
    echo "Project ID: $PROJECT_ID"
    echo "Namespace ID: $NAMESPACE_ID"
}

# Function to delete a resource if it exists
delete_resource() {
    local resource_type=$1
    local resource_name=$2
    local resource_url=$3
    local resource_id=$(make_api_call GET "$resource_url" | jq -r ".data[] | select(.name==\"$resource_name\") | .id")
    if [ ! -z "$resource_id" ] && [ "$resource_id" != "null" ]; then
        echo "Deleting existing $resource_type: $resource_name"
        make_api_call DELETE "$resource_url/$resource_id"
        sleep 5
    fi
}

# Create StorageClass if it doesn't exist
create_storage_class() {
    local STORAGE_CLASS_NAME="local-storage"
    if ! make_api_call GET "/clusters/${CLUSTER_ID}/storageClasses" | jq -e ".data[] | select(.name==\"$STORAGE_CLASS_NAME\")" > /dev/null; then
        echo "Creating StorageClass: $STORAGE_CLASS_NAME"
        make_api_call POST "/clusters/${CLUSTER_ID}/storageClasses" \
            "{\"name\":\"$STORAGE_CLASS_NAME\",\"provisioner\":\"kubernetes.io/no-provisioner\",\"volumeBindingMode\":\"WaitForFirstConsumer\"}"
        sleep 5
    fi
}

# Function to create MySQL instance
create_mysql_instance() {
    local db_name=$1
    local port=$2
    local pv_name="${db_name}-pv"
    local pvc_name="${db_name}-pvc"
    local secret_name="${db_name}-secret"
    local deployment_name="${db_name}"
    local service_name="${db_name}"

    # Create PersistentVolume
    echo "Creating PersistentVolume: $pv_name"
    make_api_call POST "/clusters/${CLUSTER_ID}/persistentVolumes" \
        "{\"name\":\"$pv_name\",\"capacity\":{\"storage\":\"1Gi\"},\"volumeMode\":\"Filesystem\",\"accessModes\":[\"ReadWriteOnce\"],\"persistentVolumeReclaimPolicy\":\"Retain\",\"storageClassId\":\"local-storage\",\"local\":{\"path\":\"/mnt/data/$db_name\"},\"nodeAffinity\":{\"required\":{\"nodeSelectorTerms\":[{\"matchExpressions\":[{\"key\":\"kubernetes.io/hostname\",\"operator\":\"In\",\"values\":[\"node1\"]}]}]}}}"
    sleep 5

    # Create PersistentVolumeClaim
    echo "Creating PersistentVolumeClaim: $pvc_name"
    make_api_call POST "/projects/${PROJECT_ID}/persistentvolumeclaims" \
        "{\"type\":\"persistentVolumeClaim\",\"namespaceId\":\"$NAMESPACE_ID\",\"name\":\"$pvc_name\",\"accessModes\":[\"ReadWriteOnce\"],\"resources\":{\"requests\":{\"storage\":\"1Gi\"}},\"storageClassId\":\"local-storage\",\"volumeId\":\"$pv_name\"}"
    sleep 5

    # Create Secret
    echo "Creating Secret: $secret_name"
    local mysql_password=$(openssl rand -base64 12)
    make_api_call POST "/projects/${PROJECT_ID}/secrets" \
        "{\"type\":\"namespacedSecret\",\"namespaceId\":\"$NAMESPACE_ID\",\"name\":\"$secret_name\",\"stringData\":{\"password\":\"$mysql_password\"}}"
    sleep 5

    # Create Deployment
    echo "Creating Deployment: $deployment_name"
    deployment_response=$(make_api_call POST "/projects/${PROJECT_ID}/workloads" \
        "{\"type\":\"deployment\",\"namespaceId\":\"$NAMESPACE_ID\",\"name\":\"$deployment_name\",\"deploymentConfig\":{\"maxSurge\":1,\"maxUnavailable\":0,\"minReadySeconds\":0,\"progressDeadlineSeconds\":600,\"revisionHistoryLimit\":10,\"strategy\":\"RollingUpdate\"},\"selector\":{\"matchLabels\":{\"app\":\"$deployment_name\"}},\"labels\":{\"app\":\"$deployment_name\"},\"containers\":[{\"name\":\"$deployment_name\",\"image\":\"mysql:5.7\",\"env\":[{\"name\":\"MYSQL_ROOT_PASSWORD\",\"valueFrom\":{\"secretKeyRef\":{\"name\":\"$secret_name\",\"key\":\"password\"}}},{\"name\":\"MYSQL_DATABASE\",\"value\":\"$db_name\"}],\"ports\":[{\"containerPort\":3306,\"name\":\"mysql\"}],\"volumeMounts\":[{\"name\":\"mysql-storage\",\"mountPath\":\"/var/lib/mysql\"}]}],\"volumes\":[{\"name\":\"mysql-storage\",\"persistentVolumeClaim\":{\"claimName\":\"$pvc_name\"}}]}")


    # Create NodePort Service
    echo "Creating NodePort Service: $service_name"
    make_api_call POST "/projects/${PROJECT_ID}/services" \
        "{\"name\":\"$service_name\",\"namespaceId\":\"$NAMESPACE_ID\",\"targetWorkloadIds\":[\"deployment:$NAMESPACE_ID:$deployment_name\"],\"selector\":{\"app\":\"$deployment_name\"},\"type\":\"NodePort\",\"ports\":[{\"name\":\"mysql\",\"port\":3306,\"targetPort\":3306,\"nodePort\":$port,\"protocol\":\"TCP\"}]}"

    # Wait for the deployment to be ready
    echo "Waiting for deployment to be ready..."
    local timeout=300
    local start_time=$(date +%s)
    while true; do
        status=$(make_api_call GET "/projects/${PROJECT_ID}/workloads/deployment:${NAMESPACE_ID}:${deployment_name}" | jq -r '.state')
        if [ "$status" == "active" ]; then
            break
        fi
        if [ $(($(date +%s) - start_time)) -gt $timeout ]; then
            echo "Timeout waiting for deployment to be ready"
            break
        fi
        sleep 5
    done

    # Get the node IP
    NODE_IP=$(make_api_call GET "/nodes" | jq -r '.data[0].ipAddress')

    echo "MySQL instance $db_name created successfully. You can connect to it using:"
    echo "Host: $NODE_IP"
    echo "Port: $port"
    echo "Database: $db_name"
    echo "Username: root"
    echo "Password: $mysql_password"
}

# Function to list MySQL instances
list_mysql_instances() {
    echo "Existing MySQL instances:"
    make_api_call GET "/projects/${PROJECT_ID}/workloads" | 
    jq -r ".data[] | select(.namespaceId==\"$NAMESPACE_ID\") | .name"
}

# Function to delete MySQL instance
delete_mysql_instance() {
    local db_name=$1
    delete_resource "PersistentVolumeClaim" "${db_name}-pvc" "/projects/${PROJECT_ID}/persistentvolumeclaims"
    delete_resource "Deployment" "$db_name" "/projects/${PROJECT_ID}/workloads"
    delete_resource "Secret" "${db_name}-secret" "/projects/${PROJECT_ID}/secrets"
    delete_resource "Service" "$db_name" "/projects/${PROJECT_ID}/services"
    delete_resource "PersistentVolume" "${db_name}-pv" "/clusters/${CLUSTER_ID}/persistentVolumes"
    echo "MySQL instance $db_name and associated resources deleted."
}

# Main execution
echo "Welcome to MySQL Service Creator"
echo "================================"

get_cluster_project_namespace_ids
create_storage_class

while true; do
    echo -e "\nChoose an option:"
    echo "1. Create a new MySQL instance"
    echo "2. List existing MySQL instances"
    echo "3. Delete a MySQL instance"
    echo "4. Exit"
    read -p "Enter your choice (1-4): " choice

    case $choice in
        1)
            read -p "Enter a name for the new MySQL instance: " db_name
            while true; do
                read -p "Enter a NodePort (30000-32767) for this instance: " port
                if [[ $port =~ ^[3][0-2][0-9]{3}$ ]] && [ $port -ge 30000 ] && [ $port -le 32767 ]; then
                    break
                else
                    echo "Invalid port number. Please enter a number between 30000 and 32767."
                fi
            done
            create_mysql_instance "$db_name" "$port"
            ;;
        2)
            list_mysql_instances
            ;;
        3)
            read -p "Enter the name of the MySQL instance to delete: " db_name
            delete_mysql_instance "$db_name"
            ;;
        4)
            echo "Exiting. Goodbye!"
            exit 0
            ;;
        *)
            echo "Invalid choice. Please enter a number between 1 and 4."
            ;;
    esac
done