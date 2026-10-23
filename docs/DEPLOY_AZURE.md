# Deploy CloudShop to one Azure VM (Ubuntu 24.04 LTS, Central India)

This is the Stage 2 deployment: one Azure VM, one Docker container, plain HTTP
on port 8000. No load balancer, no VM Scale Set and no Azure credentials in the
application. Docker Compose is installed now so later stages can run the Level 1
multi-replica setup (compose + nginx).

All resources live in the resource group **`rg-predictive-cloud`** in
**Central India (`centralindia`)**.

## 1. AWS-to-Azure mapping

| AWS concept | Azure equivalent |
|---|---|
| EC2 instance | Azure Virtual Machine |
| Security Group | Network Security Group (NSG) |
| Elastic IP / public IPv4 | Standard static public IP |
| IAM role | Managed identity + Azure RBAC role assignment |
| Amazon ECR | Azure Container Registry (ACR) |
| Amazon CloudWatch | Azure Monitor |
| EC2 Auto Scaling Group | Virtual Machine Scale Set (VMSS) |
| Application Load Balancer | Azure Load Balancer or Application Gateway |
| `ap-south-1` (Mumbai) | Central India (`centralindia`) |
| boto3 / AWS SDK | Azure SDK (`azure-identity`, `azure-mgmt-*`) |

## 2. Choose the VM size

| Size | vCPU | RAM | Use |
|---|---|---|---|
| **Standard_D2s_v3** | **2** | **8 GiB** | **Recommended: general purpose, non-burstable** |
| Standard_B2s | 2 | 4 GiB | Budget choice, burstable CPU credits |
| Standard_D4s_v3 | 4 | 16 GiB | Later, for 3-4 app replicas + nginx |
| Standard_B1s | 1 | 1 GiB | Do not use for this project |

Use **Standard_D2s_v3** (or the newer `Standard_D2s_v5` if your subscription
offers it). The B-series is cheaper but accumulates and consumes CPU credits;
long load tests can exhaust them and distort your measurements. If budget is the
priority, `Standard_B2s` still has 2 vCPUs but accept that caveat.

### Why 1 vCPU makes multi-replica scaling meaningless

Containers on one VM share the VM's CPU. With 1 vCPU, adding app replicas does
not add compute capacity: the host time-slices the same core across containers,
so aggregate throughput stays roughly flat while context switching and queueing
can make p95 latency worse. Per-replica CPU limits also stop being meaningful,
because two replicas limited to 0.5 CPU each still total one core.

With 2 or more vCPUs, replicas can execute in parallel. For example, two
replicas limited to 0.75 CPU each can use 1.5 cores while leaving headroom for
nginx and monitoring. That is the minimum needed to observe a real scale-out
effect. A 1-vCPU size such as `Standard_B1s` (1 GiB RAM) also risks OOM failures
once nginx and several API containers run together.

## 3. Find your public IP (Windows PowerShell)

```powershell
(Invoke-RestMethod -Uri "https://api.ipify.org").Trim()
```

Use the result as the source for both NSG rules, written as `YOUR_IP/32`.

## 4. Create the resource group

1. Open the Azure Portal and select **Central India** as the region.
2. Go to **Resource groups > Create**.
3. Subscription: your subscription.
4. Resource group: `rg-predictive-cloud`.
5. Region: **Central India**.
6. Select **Review + create**, then **Create**.

## 5. Create the network security group (NSG)

Create the NSG before the VM so you can attach it during VM creation and avoid
temporary broad access.

1. Go to **Network security groups > Create**.
2. Resource group: `rg-predictive-cloud`.
3. Name: `cloudshop-nsg`.
4. Region: **Central India**.
5. Create it, then open **Inbound security rules > Add** twice:

| Rule | Source | Source ports | Destination | Destination ports | Protocol | Action | Priority |
|---|---|---|---|---|---|---|---|
| `Allow-SSH-22` | IP Addresses | `YOUR_IP/32` | Any | `22` | TCP | Allow | `1000` |
| `Allow-CloudShop-8000` | IP Addresses | `YOUR_IP/32` | Any | `8000` | TCP | Allow | `1010` |

Leave outbound rules at their defaults. Do not add `Any`/`0.0.0.0/0` rules for
ports 22 or 8000.

If your ISP changes your public IP, update both rules. Azure evaluates rules by
priority (lower number first); the default rules (`65000+`) deny inbound traffic
that is not explicitly allowed.

## 6. Create the VM

1. Go to **Virtual machines > Create > Azure virtual machine**.
2. **Basics**:
   - Resource group: `rg-predictive-cloud`.
   - Virtual machine name: `cloudshop-vm`.
   - Region: **Central India**.
   - Availability options: **No infrastructure redundancy required**.
   - Security type: **Standard**.
   - Image: **Ubuntu 24.04 LTS - x64 Gen2**.
   - Size: **Standard_D2s_v3** (2 vCPU, 8 GiB).
   - Authentication type: **SSH public key**.
   - Username: `azureuser`.
   - SSH public key source: **Generate new key pair**.
   - Key pair name: `cloudshop-azure-key`.
   - Public inbound ports: **None** (the NSG rules provide access).
3. **Disks**: OS disk type **Standard SSD**, size **30 GiB** (the default is
   fine; 30 GiB is enough for Docker images and logs).
4. **Networking**:
   - Virtual network/subnet: accept the defaults (new VNet).
   - Public IP: **Create new**.
     - Name: `cloudshop-public-ip`.
     - SKU: **Standard**.
     - Assignment: **Static**.
     - Optionally set a DNS name label, for example `cloudshop-yourname`, to get
       a stable name like
       `cloudshop-yourname.centralindia.cloudapp.azure.com`.
   - NIC network security group: **Advanced**, then select the existing
     `cloudshop-nsg`.
5. **Management**: optionally enable **Auto-shutdown** for development. It stops
   the VM but does not delete its disk or public IP.
6. **Review + create**, then **Create**.
7. When prompted, **download the private key** (`cloudshop-azure-key.pem`) and
   store it at a known path such as `C:\keys\cloudshop-azure-key.pem`. Azure
   does not let you download it again.
8. Wait for deployment, then note the VM's **Public IP address** (or DNS name).

The public IP is static, so it survives a stop/deallocate. The VM is billed
while running; deallocating it stops compute billing, but the disk and public IP
can still incur small charges.

## 7. Fix the key permissions on Windows

OpenSSH on Windows rejects private keys that other users can read. Replace the
path with your key path:

```powershell
icacls "C:\keys\cloudshop-azure-key.pem" /inheritance:r
icacls "C:\keys\cloudshop-azure-key.pem" /grant:r "$($env:USERNAME):(R)"
```

## 8. Connect over SSH

```powershell
ssh -i "C:\keys\cloudshop-azure-key.pem" azureuser@YOUR_AZURE_PUBLIC_IP
```

Or use the DNS name:

```powershell
ssh -i "C:\keys\cloudshop-azure-key.pem" `
  azureuser@cloudshop-yourname.centralindia.cloudapp.azure.com
```

Accept the host fingerprint on the first connection.

## 9. Install Docker Engine and the Compose plugin

Run these on the VM:

```bash
sudo apt-get update
sudo apt-get install -y ca-certificates curl

sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

sudo apt-get update
sudo apt-get install -y \
  docker-ce docker-ce-cli containerd.io \
  docker-buildx-plugin docker-compose-plugin

sudo systemctl enable --now docker
docker --version
docker compose version
```

`docker-compose-plugin` installs the v2 plugin, so `docker compose version` must
print a v2 version.

Allow `azureuser` to run Docker without sudo, then reconnect so the group change
takes effect:

```bash
sudo usermod -aG docker azureuser
exit
```

SSH back in and verify:

```bash
docker info
```

If you see `permission denied while trying to connect to the Docker daemon`,
the `docker` group is not active yet. Log out and back in, or run
`newgrp docker` in that shell.

## 10. Copy the project from PowerShell and start it

### Recommended: use deploy/deploy.ps1

From the project root on your Windows machine:

```powershell
cd C:\Users\Dell\Desktop\cloudshop
.\deploy\deploy.ps1 -KeyPath "C:\keys\cloudshop-azure-key.pem" -AzureHost "YOUR_AZURE_PUBLIC_IP"
```

If PowerShell blocks the script, run it explicitly:

```powershell
powershell -ExecutionPolicy Bypass -File .\deploy\deploy.ps1 `
  -KeyPath "C:\keys\cloudshop-azure-key.pem" -AzureHost "YOUR_AZURE_PUBLIC_IP"
```

The script:

1. Creates `~/cloudshop` on the VM (default remote directory).
2. Copies `app/`, `requirements-api.txt`, `Dockerfile` and `.dockerignore`
   with `scp`. It does not copy `.venv`, tests, datasets or results.
3. Builds `cloudshop-api:1.0` on the VM.
4. Removes the old `cloudshop` container and starts a new one with
   `--restart unless-stopped` on port 8000.
5. Prints the container status and checks `http://YOUR_AZURE_PUBLIC_IP:8000/health`.

Optional parameters:

```powershell
.\deploy\deploy.ps1 `
  -KeyPath "C:\keys\cloudshop-azure-key.pem" `
  -AzureHost "cloudshop-yourname.centralindia.cloudapp.azure.com" `
  -RemoteUser "azureuser" `
  -RemoteDir "cloudshop" `
  -ImageTag "cloudshop-api:1.0" `
  -ContainerName "cloudshop" `
  -Port 8000
```

### Manual equivalent

```powershell
$AZURE_IP = "YOUR_AZURE_PUBLIC_IP"

ssh -i "C:\keys\cloudshop-azure-key.pem" azureuser@$AZURE_IP "mkdir -p ~/cloudshop"

scp -i "C:\keys\cloudshop-azure-key.pem" -r `
  app requirements-api.txt Dockerfile .dockerignore `
  azureuser@${AZURE_IP}:~/cloudshop/
```

Then on the VM:

```bash
cd ~/cloudshop
docker build -t cloudshop-api:1.0 .
docker rm -f cloudshop 2>/dev/null || true
docker run -d --name cloudshop --restart unless-stopped \
  -p 8000:8000 cloudshop-api:1.0
docker ps
docker logs --tail 50 cloudshop
```

## 11. Verify from PowerShell

```powershell
$AZURE_IP = "YOUR_AZURE_PUBLIC_IP"
Invoke-RestMethod "http://$AZURE_IP:8000/health"
Invoke-RestMethod "http://$AZURE_IP:8000/products"
Invoke-RestMethod "http://$AZURE_IP:8000/products/1"
Invoke-RestMethod "http://$AZURE_IP:8000/search?q=laptop"
Invoke-RestMethod -Method Post -Uri "http://$AZURE_IP:8000/orders" `
  -ContentType "application/json" -Body '{"product_id":1,"quantity":2}'
```

Expected:

- `/health` returns `{"status":"ok"}`
- `/products` returns 5 products
- `/products/1` returns Smartphone
- `/search?q=laptop` returns Laptop
- `POST /orders` returns `201` with `total_price: 31998`
- `http://YOUR_AZURE_PUBLIC_IP:8000/docs` opens the API documentation
- Missing product IDs return `404`

## 12. Troubleshooting

| Symptom | Check |
|---|---|
| Request to port 8000 times out | NSG rule source is your current IP/32, rule priority, container running (`docker ps`), port mapping (`-p 8000:8000`) |
| SSH connection times out | NSG SSH rule, VM is running (not deallocated), correct public IP/DNS name |
| `Permission denied (publickey)` | Correct key pair for this VM, key path, `icacls` permissions, username `azureuser` |
| `permission denied ... Docker daemon` | Reconnect after `usermod -aG docker azureuser`, or use `sudo docker` temporarily |
| `docker compose` not found | Install `docker-compose-plugin` and check `docker compose version` |
| Container exits immediately | `docker logs cloudshop`; confirm `app/main.py` was copied and uvicorn starts |
| API works on the VM but not remotely | NSG source address, public IP changed by editing the VM, or wrong DNS name |
| Disk full during build | Check `df -h`; grow the OS disk in Azure and resize the filesystem, or prune unused images (`docker image prune`) |
| Cannot attach the NSG during creation | Create the VM with ports `None`, then associate `cloudshop-nsg` with the VM's network interface under **Networking** |

## 13. Security and cost notes

- Keep SSH and 8000 restricted to your IP in the NSG. Do not expose either to
  `Any` or `0.0.0.0/0`.
- Port 8000 is plain HTTP. It is acceptable for this temporary test setup, not
  for a public production service. TLS and a reverse proxy come later.
- No Azure credentials, service principal secrets or storage keys belong in the
  repository or the container. Later use a managed identity.
- Set a budget and alert in **Cost Management + Billing**. An alert notifies you;
  it does not stop resources automatically.
- Stop/deallocate the VM after experiments. The static public IP and managed disk
  can still incur small charges while they exist.
- To remove everything at the end of the project, delete the resource group
  `rg-predictive-cloud`. This deletes the VM, disk, NIC, NSG and public IP.
- Do not create a Load Balancer or VM Scale Set yet. Those belong to the advanced
  scaling stage and add cost.
