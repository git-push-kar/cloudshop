# Deploy CloudShop to one EC2 instance (Amazon Linux 2023, ap-south-1)

This is the Stage 2 deployment: one EC2 VM, one Docker container, plain HTTP on
port 8000. No load balancer, no Auto Scaling Group and no AWS credentials in the
application. The Docker Compose plugin is installed now so later stages can run
the Level 1 multi-replica setup (compose + nginx).

## 1. Choose the instance type

| Instance type | vCPU | RAM | Use |
|---|---|---|---|
| **t3.medium** | **2** | **4 GiB** | **Recommended minimum for this stage** |
| t3.large | 2 | 8 GiB | More headroom if nginx/controller also run on the VM |
| m5.large | 2 | 8 GiB | Non-burstable CPU, better for long repeatable load tests |
| t3.xlarge | 4 | 16 GiB | Useful later for 3-4 app replicas with CPU limits |
| t2.micro / t2.small | 1 | 1-2 GiB | Do not use for this project |

Use **t3.medium (2 vCPU, 4 GiB, x86_64)** as the default. Its CPU is burstable:
long load tests can exhaust CPU credits and distort results. If you need steady
throughput for the final experiments, use **m5.large** instead, or enable T3
Unlimited (which can cost extra). You can stop the instance later and change its
type without rebuilding the deployment.

### Why 1 vCPU makes multi-replica scaling meaningless

Containers on one VM share the VM's CPU. With 1 vCPU, adding app replicas does
not add compute capacity: Docker time-slices the same core across containers, so
aggregate throughput stays roughly flat while context switching and queueing can
make p95 latency worse. Per-replica CPU limits also become meaningless because
two replicas at 0.5 CPU each still total one core.

With 2 or more vCPUs, replicas can run in parallel. For example, two replicas
limited to 0.75 CPU each can use 1.5 cores while leaving headroom for nginx and
monitoring. That is the minimum needed to observe a real scale-out effect. A
1 vCPU instance such as t2.micro/t2.small, usually with only 1-2 GiB of RAM, also
risks OOM failures once nginx and several API containers run together.

## 2. Find your public IP (Windows PowerShell)

```powershell
(Invoke-RestMethod -Uri "https://checkip.amazonaws.com").Trim()
```

The result is your current public IPv4 address. Use it as the source for the
SSH and 8000 rules below (AWS displays it as `x.x.x.x/32`).

## 3. Launch the instance (AWS Console)

1. Open the AWS Console and select region **Asia Pacific (Mumbai) / ap-south-1**.
2. Go to **EC2 > Instances > Launch instances**.
3. Name: `cloudshop-api`.
4. AMI: **Amazon Linux 2023** (64-bit x86_64).
5. Instance type: **t3.medium**.
6. Key pair: **Create new key pair**.
   - Name: `cloudshop-key`
   - Type: RSA
   - Format: `.pem`
   - Download it and keep the path, for example `C:\keys\cloudshop-key.pem`.
7. Network settings:
   - VPC/subnet: default is fine.
   - Auto-assign public IP: **Enable**.
   - Firewall: **Create security group** named `cloudshop-sg`.
   - Inbound rules (remove any default SSH rule that allows `0.0.0.0/0`):
     - **SSH**, TCP, port **22**, source **My IP**.
     - **Custom TCP**, TCP, port **8000**, source **My IP**.
   - Outbound rules: leave the default (all traffic). The VM needs this for OS
     updates and pulling the Docker Compose binary.
8. Storage: **16 GiB gp3** is enough (the Docker image is small; 8 GiB also
   works but leaves less room for logs and caches).
9. IAM instance profile: none needed for Stage 2.
10. Launch the instance.
11. Note the instance's **Public IPv4 address** (or public DNS name). The public
    IP changes if you stop and start the instance unless you attach an Elastic
    IP; do not allocate one yet.

Security group summary:

| Direction | Protocol | Port | Source/destination | Purpose |
|---|---|---|---|---|
| Inbound | TCP | 22 | your IP /32 | SSH |
| Inbound | TCP | 8000 | your IP /32 | CloudShop API |
| Outbound | All | All | 0.0.0.0/0 | updates, image pulls |

Do not open port 8000 to the whole internet. If your ISP changes your IP, update
both inbound rules.

## 4. Fix the key permissions on Windows

OpenSSH on Windows rejects private keys that other users can read. In
PowerShell, replace the path with your key path:

```powershell
icacls "C:\keys\cloudshop-key.pem" /inheritance:r
icacls "C:\keys\cloudshop-key.pem" /grant:r "$($env:USERNAME):(R)"
```

## 5. Connect over SSH

```powershell
ssh -i "C:\keys\cloudshop-key.pem" ec2-user@YOUR_EC2_PUBLIC_IP
```

Accept the host fingerprint on the first connection. Amazon Linux uses the
username `ec2-user`.

## 6. Install Docker on Amazon Linux 2023

Run these on the EC2 instance:

```bash
sudo dnf update -y
sudo dnf install -y docker
sudo systemctl enable --now docker
sudo docker version
```

Allow `ec2-user` to run Docker without sudo, then reconnect so the group change
takes effect:

```bash
sudo usermod -aG docker ec2-user
exit
```

SSH back in and verify:

```bash
docker info
```

If you see `permission denied while trying to connect to the Docker daemon`,
the `docker` group is not active yet. Log out and back in, or run
`newgrp docker` in that shell.

## 7. Install the Docker Compose plugin

Compose is not used in Stage 2, but install it now for the Level 1 multi-replica
stage. On the recommended x86_64 instance:

```bash
sudo mkdir -p /usr/local/lib/docker/cli-plugins
sudo curl -SL "https://github.com/docker/compose/releases/latest/download/docker-compose-linux-x86_64" \
  -o /usr/local/lib/docker/cli-plugins/docker-compose
sudo chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
docker compose version
```

`docker compose version` must print a v2 version. If you choose an ARM/Graviton
instance later, use the `docker-compose-linux-aarch64` binary instead.

## 8. Copy the project from PowerShell and start it

### Recommended: use deploy/deploy.ps1

From the project root on your Windows machine:

```powershell
cd C:\Users\Dell\Desktop\cloudshop
.\deploy\deploy.ps1 -KeyPath "C:\keys\cloudshop-key.pem" -EC2Host "YOUR_EC2_PUBLIC_IP"
```

If PowerShell blocks the script, run it explicitly:

```powershell
powershell -ExecutionPolicy Bypass -File .\deploy\deploy.ps1 `
  -KeyPath "C:\keys\cloudshop-key.pem" -EC2Host "YOUR_EC2_PUBLIC_IP"
```

The script:

1. Creates `~/cloudshop` on the instance (default remote directory).
2. Copies `app/`, `requirements-api.txt`, `Dockerfile` and `.dockerignore`
   with `scp`. It does not copy `.venv`, tests, datasets or results.
3. Builds `cloudshop-api:1.0` on the instance.
4. Removes the old `cloudshop` container and starts a new one with
   `--restart unless-stopped` on port 8000.
5. Prints the container status and checks `http://YOUR_EC2_PUBLIC_IP:8000/health`.

Optional parameters:

```powershell
.\deploy\deploy.ps1 `
  -KeyPath "C:\keys\cloudshop-key.pem" `
  -EC2Host "YOUR_EC2_PUBLIC_IP" `
  -RemoteUser "ec2-user" `
  -RemoteDir "cloudshop" `
  -ImageTag "cloudshop-api:1.0" `
  -ContainerName "cloudshop" `
  -Port 8000
```

### Manual equivalent

```powershell
$EC2_IP = "YOUR_EC2_PUBLIC_IP"

ssh -i "C:\keys\cloudshop-key.pem" ec2-user@$EC2_IP "mkdir -p ~/cloudshop"

scp -i "C:\keys\cloudshop-key.pem" -r `
  app requirements-api.txt Dockerfile .dockerignore `
  ec2-user@${EC2_IP}:~/cloudshop/
```

Then on the instance:

```bash
cd ~/cloudshop
docker build -t cloudshop-api:1.0 .
docker rm -f cloudshop 2>/dev/null || true
docker run -d --name cloudshop --restart unless-stopped \
  -p 8000:8000 cloudshop-api:1.0
docker ps
docker logs --tail 50 cloudshop
```

## 9. Verify from PowerShell

```powershell
$EC2_IP = "YOUR_EC2_PUBLIC_IP"
Invoke-RestMethod "http://$EC2_IP:8000/health"
Invoke-RestMethod "http://$EC2_IP:8000/products"
Invoke-RestMethod "http://$EC2_IP:8000/products/1"
Invoke-RestMethod "http://$EC2_IP:8000/search?q=laptop"
Invoke-RestMethod -Method Post -Uri "http://$EC2_IP:8000/orders" `
  -ContentType "application/json" -Body '{"product_id":1,"quantity":2}'
```

Expected:

- `/health` returns `{"status":"ok"}`
- `/products` returns 5 products
- `/products/1` returns Smartphone
- `/search?q=laptop` returns Laptop
- `POST /orders` returns `201` with `total_price: 31998`
- `http://YOUR_EC2_PUBLIC_IP:8000/docs` opens the API documentation
- Missing product IDs return `404`

## 10. Troubleshooting

| Symptom | Check |
|---|---|
| Request to port 8000 times out | Security group source address, current public IP, container running (`docker ps`), port mapping (`-p 8000:8000`) |
| `Connection refused` on SSH | Port 22 rule, instance running, correct public IP, key file |
| `Permission denied (publickey)` | Correct key pair for this instance, key path, `icacls` permissions |
| `permission denied ... Docker daemon` | Re-login after `usermod -aG docker ec2-user`, or use `sudo docker` temporarily |
| `docker compose` not found | Re-run the Compose plugin install step and check `docker compose version` |
| Container exits immediately | `docker logs cloudshop`; confirm `app/main.py` was copied and uvicorn starts |
| API works on the VM but not remotely | The 8000 rule is still limited to your old public IP |
| Disk full during build | Check `df -h`; increase the EBS volume or prune unused images (`docker image prune`) |

## 11. Security and cost notes

- Keep SSH and 8000 restricted to your IP. Do not expose either to `0.0.0.0/0`.
- Port 8000 is plain HTTP. It is acceptable for this temporary test setup, not
  for a public production service. TLS and a reverse proxy come later.
- No AWS access keys are stored in the repository or the container.
- Stop (not just disconnect) the instance after experiments to avoid charges.
  Starting it again may assign a different public IP.
- Do not create an Application Load Balancer or Auto Scaling Group yet. Those
  belong to the advanced scaling stage and add cost.
- Docker Compose and the nginx-based multi-replica setup are next; this stage
  intentionally runs a single container.
